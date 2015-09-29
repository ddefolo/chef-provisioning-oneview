module CreateMachine
  private

  # Chef oneview provisioning
  def create_machine(action_handler, machine_spec, machine_options)
    host_name = machine_options[:driver_options][:host_name]
    server_template = machine_options[:driver_options][:server_template]

    auth_tokens # Login (to both ICSP and OneView)

    # Check if profile exists first
    matching_profiles = rest_api(:oneview, :get, "/rest/server-profiles?filter=name matches '#{host_name}'&sort=name:asc")
    if matching_profiles['count'] > 0
      profile = matching_profiles['members'].first
      power_on(action_handler, machine_spec, profile['serverHardwareUri']) # Make sure server is started
      return profile
    end

    # Search for OneView Template by name
    templates = rest_api(:oneview, :get, "/rest/server-profiles?filter=name matches '#{server_template}'&sort=name:asc")
    unless templates['members'] && templates['members'].count > 0
      fail "Template '#{server_template}' not found! Please match the template name with one that exists on OneView."
    end
    template_uri = templates['members'].first['uri']

    # Get first availabe (and compatible) HP OV server blade
    chosen_blade = available_hardware_for_template(templates['members'].first)

    power_off(action_handler, machine_spec, chosen_blade['uri'])

    # Create new profile instance from template
    action_handler.perform_action "Initialize creation of server profile for #{machine_spec.name}" do
      action_handler.report_progress "INFO: Initializing creation of server profile for #{machine_spec.name}"

      new_template_profile = rest_api(:oneview, :get, "#{template_uri}")

      # Take response, add name & hardware uri, and post back to /rest/server-profiles
      new_template_profile['name'] = host_name
      new_template_profile['uri'] = nil
      new_template_profile['serialNumber'] = nil
      new_template_profile['uuid'] = nil
      new_template_profile['taskUri'] = nil
      new_template_profile['connections'].each do |c|
        c['wwnn'] = nil
        c['wwpn'] = nil
        c['mac']  = nil
        # CSAEQUIV
        # I also zero out following - not sure if must
        #c['deploymentStatus'] = nil
        #c['interconnectUri'] = nil

        # not keeping orig value here might be important if the appliance
        # virt/physical preference has changed 
        #c['wwpnType'] = nil
        #c['macType'] = nil
        
      end

      if !new_template_profile['sanStorage'].nil?
        new_template_profile['sanStorage'] = update_san_info(new_template_profile['sanStorage'], chose_blade['name'])
      end

      new_template_profile['serverHardwareUri'] = chosen_blade['uri']
      task = rest_api(:oneview, :post, '/rest/server-profiles', { 'body' => new_template_profile })
      task_uri = task['uri']
      # Wait for profile to be applied
      60.times do # Wait for up to 5 min
        matching_profiles = rest_api(:oneview, :get, "/rest/server-profiles?filter=name matches '#{host_name}'&sort=name:asc")
        break if matching_profiles['count'] > 0
        print '.'
        sleep 5
      end
      unless matching_profiles['count'] > 0
        task = rest_api(:oneview, :get, task_uri)
        fail "Server profile couldn't be created! #{task['taskStatus']}. #{task['taskErrors'].first['message']}"
      end
    end
    assigned_profile = matching_profiles['members'].first
    boot_from_san_profile = enable_boot_from_san(assigned_profile)
    boot_from_san_profile
  end
 
  =begin
  TODO: need to refactor where the below logic goes.  We don't want to
        do this until after the original profile is applied as the 
        storage targets will be nil until after the original assignment
        task is done or mostly done.  
        I see the below customize_machine.rb waits for the profile, but
        if I move this there I lose acess to the fill_volume_details method
  =end 
  def enable_boot_from_san(profile)
    if !profile['sanStorage'].nil?
      if !profile['connections'].nil? && !profile['sanStorage']['volumeAttachements'].nil?
        # if there is a san volume we might need to update boot connections
        update_needed = false
        profile['sanStorage']['volumeAttachements'].each do |v|
        full_vol_info = fill_volume_details(v)
        if full_vol_info['volumeName'].downcase =~ /^boot/
          # find the enabled path(s), get target wwpn, and then update
          # connection setting boot targets
          v['storagePaths'].each do |s|
            if !s['isEnabled'].nil? && !s[storageTargets].nil? && !s[storageTargets].first.nil?
              target = {}
              boot_connection = s['connectionId']
              target['arrayWwpn'] = s[storageTargets].first
              target['lun'] = full_vol_info['lun']
              profile['connections'].each do |c|
                if c['id'] == boot_connection
                  fail "ERROR: profile has a volume labeled for 'boot', but the 'Manage boot order' setting has not been selected.  Remove the volume or select the 'Manage boot order' setting and specify Primary and Secondary boot targets in the connections settings." if c['boot'].nil?
                  c['boot']['targets'] = [target]
                  update_needed = true
                end
              end
            end 
          end
        end
      end
    end
    if update_needed 
      task = rest_api(:oneview, :put, profile['uri'], { 'body' => profile })
      task_uri = task['uri']
      # Wait for profile to be updated
      task = nil
      60.times do # Wait for up to 5 min
        task = rest_api(:oneview, :get, task_uri)
        break if task['percentComplete'] == '100'
        print '.'
        sleep 5
      end
    end
    task = rest_api(:oneview, :get, profile['uri'])
  end

  def update_san_info(san_storage, suffix)
    if !san_storage['volumeAttachements'].nil?
      # Sanitize old SAN entries and fill in details
      boot_vols = 0
      san_storage['volumeAttachements'].each do |v|
        v['state'] = nil
        v['status'] = nil      
        v['storagePaths'].each do |s|
          v['status'] = nil      
        end
        full_vol_info = fill_volume_details(v)
 
        # could get regexp to match boot disk from config file
        if full_vol_info['volumeName'].downcase =~ /^boot/
          boot_vols += 1
        end
        
        fail "Should know if volume is sharable" if full_vol_info['volumeShareble'].nil?
        
        if full_vol_info['volumeSharable'].downcase == 'false'
          # its private in the template so we will clone it
          full_vol_info['volumeUri'] = nil
          
          # might want some global config to control this
          # for now assume all cloned volumes are non-permanet
          full_vol_info['permanent'] = 'false'

          if full_vol_info['lunType'].downcase == 'auto'
            full_vol_info['lun'] = nil
          end
          if !suffix.nil?
            full_vol_info['volumeName'].concat(" " + suffix)
          end

          # does this update the entry in the array?
          v = full_vol_info
        end
      end
    end
    fail "There should be only 1 volume with a name that starts with boot" if boot_vols > 1
    san_storage
  end

  # read in details of volume that are missing from template profile
  def fill_volume_details(v)
    volume_uri = v['volumeUri'}
    details = rest_api(:oneview, :get, "/rest/index/resources/#{volume_uri}")
    v['volumeName'] = details['name']
    attribs = volumeDatails['attributes']
    if !attribs.nil 
      v['permanent'] = attribs['storage_volume_ispermanent']
      v['volumeShareable'] = attribs['storage_volume_shareable']
      v['volumeProvisionType'] = attribs['storage_volume_provision_type']
      v['volumeProvisionedCapacityBytes'] = attribs['storage_volume_provisioned_capacity']
      v['volumeDescription'] = attribs['storage_volume_provisioned_description']
    end
    v
  end
