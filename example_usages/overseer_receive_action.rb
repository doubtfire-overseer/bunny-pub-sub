# frozen_string_literal: true

require 'zip'
require 'securerandom'
require 'yaml'

module Execution
  RUN = 'run'
  BUILD = 'build'
  DOCKER_WORKDIR = 'app'
  DOCKER_OUTDIR = 'var/lib/overseer'
end

def ack_result(results_publisher, task_id, timestamp, output_path)
  return if results_publisher.nil?

  msg = { task_id: task_id, timestamp: timestamp }

  results_publisher.connect_publisher
  results_publisher.publish_message msg
  results_publisher.disconnect_publisher
end

def valid_zip?(file)
  begin
    zip = Zip::File.open(file)
    return true
  rescue StandardError => e
    raise e
  ensure
    zip&.close
  end
  false
end

# Flat extract a zip file, no sub-directories.
def extract_zip(input_zip_file_path, output_loc)
  Zip::File.open(input_zip_file_path) do |zip_file|
    # Handle entries one by one
    zip_file.each do |entry|
      # Extract to file/directory/symlink
      puts "Extracting #{entry.name} #{entry.ftype}"
      pn = Pathname.new entry.name
      unless entry.ftype.to_s == 'directory'
        entry.extract "#{output_loc}/#{pn.basename}"
      end
    end
    # # Find specific entry
    # entry = zip_file.glob('*.csv').first
    # puts entry.get_input_stream.read
  end
end

def get_task_path(task_id)
  "student_projects/task_#{task_id}"
end

def get_docker_task_execution_path
  # Docker volumes needs absolute source and destination paths
  "#{Dir.pwd}/#{Execution::DOCKER_WORKDIR}/sandbox"
end

def get_docker_task_output_path
  # Docker volumes needs absolute source and destination paths
  "#{Dir.pwd}/#{Execution::DOCKER_WORKDIR}/output"
end

##################################################################
##################################################################

# Step 1 -- done
def copy_student_files(s_path, d_path)
  puts 'Copying submission files'
  `cp -R #{s_path}/. #{d_path}`
end

def extract_submission(zip_file, d_path)
  puts 'Extracting submission from zip file'
  extract_zip zip_file, d_path
end

# Step 2 -- done
def extract_assessment(zip_file, path)
  extract_zip zip_file, path
end

# Step 3
def run_assessment_script(path)
  rpath = "#{path}/run.sh"
  unless File.exist? rpath
    client_error!({ error: "File #{rpath} doesn't exist" }, 400)
  end
  result = {}

  `chmod +x #{rpath}`

  Dir.chdir path do
    result = { run_result_message: `./run.sh` }
  end
  result
end

def run_assessment_script_via_docker(s_path, output_path, random_string, exec_mode, command, tag)
  client_error!({ error: "A valid Docker image name:tag is needed" }, 400) if tag.nil? || tag.to_s.strip.empty?

  puts 'Running docker executable..'

  # TODO: Security:
  # Pass random filename... both `blah.txt` and `blah.yaml`
  # Permit write access ONLY to these files
  # Other security like no network access, capped execution time + resources, etc

  # test:
  # -m 100MB done
  # --stop-timeout 10 (seconds) (isn't for what I thought it was :))
  # --network none (fails reading from https://api.nuget.org/v3/index.json)
  # --read-only (FAILURE without correct exit code)
  # https://docs.docker.com/engine/reference/run/#security-configuration
  # https://docs.docker.com/engine/reference/run/#runtime-constraints-on-resources
  # -u="overseer" (specify default non-root user)

  result = {
    run_result_message:
    `docker run \
    -m 100MB \
    --restart no \
    --volume #{s_path}:/#{Execution::DOCKER_WORKDIR} \
    --volume #{get_docker_task_output_path}:/#{Execution::DOCKER_OUTDIR}\
    --name container1 \
    #{tag} \
    /bin/bash -c "#{command}"`
  }

  puts "Docker container exit status code: #{$?.exitstatus}"

  extract_result_files get_docker_task_output_path, output_path, random_string, $?.exitstatus

  diff_result = `docker diff container1`
  puts "docker diff: \n#{!diff_result&.strip&.empty? ? diff_result : 'nothing changed' }"

  extract_docker_diff_file output_path, diff_result, exec_mode

  rm_container_result = `docker container rm container1`
  puts "rm_container_result: #{rm_container_result}"

  if $?.exitstatus != 0
    raise Subscriber::ServerException.new result, 500
  end
end

# Step 4
def extract_result_files(s_path, output_path, random_string, exitstatus)
  client_error!({ error: "A valid output_path is needed" }, 400) if output_path.nil? || output_path.to_s.strip.empty?

  puts 'Extracting result file from the pit..'
  FileUtils.mkdir_p output_path

  input_txt_file_name = "#{s_path}/#{random_string}.txt"
  output_txt_file_name = "#{output_path}/output.txt"
  input_yaml_file_name = "#{s_path}/#{random_string}.yaml"
  output_yaml_file_name = "#{output_path}/output.yaml"

  if File.exist? input_txt_file_name
    File.open(input_txt_file_name, 'a') { |f|
      f.puts "exit code: #{exitstatus}"
    }

    if File.exist? output_txt_file_name
      to_append = File.read input_txt_file_name
      File.open(output_txt_file_name, 'a') { |f|
        f.puts ''
        f.puts to_append
      }
    else
      FileUtils.copy(input_txt_file_name, output_txt_file_name)
    end

    FileUtils.rm input_txt_file_name
  else
    puts "Results file: #{s_path}/#{random_string}.txt does not exist"
  end

  # Update status from `blah.yaml`... if it exists etc.
  if File.exist? input_yaml_file_name
    File.open(input_yaml_file_name, 'a') { |f|
      f.puts "exit_code: #{exitstatus}"
    }

    if File.exist? output_yaml_file_name
      output_yaml = YAML.load_file(output_yaml_file_name)
      input_yaml = YAML.load_file(input_yaml_file_name)

      # Merge yaml files.
      output_yaml.merge! input_yaml
      File.open(output_yaml_file_name, 'w') { |f|
        f.puts output_yaml.to_yaml
      }
    else
      FileUtils.copy(input_yaml_file_name, output_yaml_file_name)
    end

    FileUtils.rm input_yaml_file_name
  else
    puts "Results file: #{s_path}/#{random_string}.yaml does not exist"
  end

end

def extract_docker_diff_file(output_path, diff, exec_mode)
  File.write("#{output_path}/#{exec_mode}-diff.txt", diff)
end

# Step 5
def cleanup_after_your_own_mess(path)
  return if path.nil?
  return unless File.exist? path

  puts "Recursively force removing: #{path}/*"
  FileUtils.rm_rf(Dir.glob("#{path}/*"))
end

def clean_before_start(path)
  cleanup_after_your_own_mess(path)
end

def valid_zip_file_param?(params)
  !params['zip_file'].nil? && params['zip_file'].is_a?(Integer) && params['zip_file'] == 1
end

def receive(subscriber_instance, channel, results_publisher, delivery_info, _properties, params)
  params = JSON.parse(params)
  return subscriber_instance.client_error!({error: 'PARAM `docker_image_name_tag` is required'}, 400) if params['docker_image_name_tag'].nil?
  return subscriber_instance.client_error!({error: 'PARAM `output_path` is required'}, 400) if params['output_path'].nil?
  return subscriber_instance.client_error!({error: 'PARAM `submission` is required'}, 400) if params['submission'].nil?
  return subscriber_instance.client_error!({error: 'PARAM `assessment` is required'}, 400) if params['assessment'].nil?
  return subscriber_instance.client_error!({error: 'PARAM `timestamp` is required'}, 400) if params['timestamp'].nil?
  return subscriber_instance.client_error!({error: 'PARAM `task_id` is required'}, 400) if params['task_id'].nil?

  if !ENV['RUBY_ENV'].nil? && ENV['RUBY_ENV'] == 'development'
    puts 'Running in development mode.'\
    ' Prepending ROOT_PATH to submission, assessment and output_path params.'
    root_path = ENV['ROOT_PATH']
    params['output_path'] = "#{root_path}#{params['output_path']}"
    params['submission'] = "#{root_path}#{params['submission']}"
    params['assessment'] = "#{root_path}#{params['assessment']}"
  end

  puts params

  docker_image_name_tag = params['docker_image_name_tag']
  output_path = params['output_path']
  submission = params['submission']
  assessment = params['assessment']
  timestamp = params['timestamp']
  task_id = params['task_id']

  unless task_id.is_a?(Integer)
    subscriber_instance.client_error!({ error: "Invalid task_id: #{task_id}" }, 400)
  end

  unless File.exist? submission
    if valid_zip_file_param? params
      subscriber_instance.client_error!({ error: "Zip file not found: #{submission}" }, 400)
    else
      # By default, Overseer will expect a folder path
      subscriber_instance.client_error!({ error: "Folder not found: #{submission}" }, 400)
    end
  end

  unless File.exist? assessment
    subscriber_instance.client_error!({ error: "Zip file not found: #{assessment}" }, 400)
  end

  unless valid_zip? submission
    subscriber_instance.client_error!({ error: "Invalid zip file: #{submission}" }, 400)
  end

  unless valid_zip? assessment
    subscriber_instance.client_error!({ error: "Invalid zip file: #{assessment}" }, 400)
  end

  docker_pit_path = get_docker_task_execution_path # get_task_path(task_id)
  puts "Docker execution path: #{docker_pit_path}"
  unless File.exist? docker_pit_path
    # TODO: Add correct permissions here
    FileUtils.mkdir_p docker_pit_path
  else
    clean_before_start docker_pit_path
  end

  skip_rm = params['skip_rm'] || 0

  if valid_zip_file_param? params
    extract_submission submission, docker_pit_path
  else
    copy_student_files submission, docker_pit_path
  end

  extract_assessment assessment, docker_pit_path

  random_string = "#{Execution::BUILD}-#{SecureRandom.hex}"
  run_assessment_script_via_docker(
    docker_pit_path,
    output_path,
    random_string,
    Execution::BUILD,
    "chmod +x /#{Execution::DOCKER_WORKDIR}/#{Execution::BUILD}.sh && /#{Execution::DOCKER_WORKDIR}/#{Execution::BUILD}.sh /#{Execution::DOCKER_OUTDIR}/#{random_string}.yaml >> /#{Execution::DOCKER_OUTDIR}/#{random_string}.txt",
    docker_image_name_tag
  )
  random_string = "#{Execution::RUN}-#{SecureRandom.hex}"
  run_assessment_script_via_docker(
    docker_pit_path,
    output_path,
    random_string,
    Execution::RUN,
    "chmod +x /#{Execution::DOCKER_WORKDIR}/#{Execution::RUN}.sh && /#{Execution::DOCKER_WORKDIR}/#{Execution::RUN}.sh /#{Execution::DOCKER_OUTDIR}/#{random_string}.yaml >> /#{Execution::DOCKER_OUTDIR}/#{random_string}.txt",
    docker_image_name_tag
  )

rescue Subscriber::ClientException => e
  cleanup_after_your_own_mess docker_pit_path if skip_rm != 1
  channel.ack(delivery_info.delivery_tag)
  puts e.message
  subscriber_instance.client_error!({ error: e.message, task_id: task_id, timestamp: timestamp }, e.status)
rescue Subscriber::ServerException => e
  cleanup_after_your_own_mess docker_pit_path if skip_rm != 1
  channel.ack(delivery_info.delivery_tag)
  puts e.message
  subscriber_instance.server_error!({ error: 'Internal server error', task_id: task_id, timestamp: timestamp }, 500)
rescue StandardError => e
  cleanup_after_your_own_mess docker_pit_path if skip_rm != 1
  channel.ack(delivery_info.delivery_tag)
  puts e.message
  subscriber_instance.server_error!({ error: 'Internal server error', task_id: task_id, timestamp: timestamp }, 500)
else
  cleanup_after_your_own_mess docker_pit_path if skip_rm != 1
  channel.ack(delivery_info.delivery_tag)
  ack_result results_publisher, task_id, timestamp, output_path
end
