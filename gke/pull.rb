# coding: utf-8

require "yaml"
require "kura"
require "google/apis/pubsub_v1"
require "google/apis/storage_v1"
require "google/apis/cloudiot_v1"

class Pubsub
  def initialize
    # use default credential
    @api = Google::Apis::PubsubV1::PubsubService.new
    @api.authorization = Google::Auth.get_application_default(["https://www.googleapis.com/auth/cloud-platform"])
    @api.authorization.fetch_access_token!
    @api.client_options.open_timeout_sec = 10
    @api.client_options.read_timeout_sec = 600
  end

  def pull(subscription)
    ret = @api.pull_subscription(subscription, Google::Apis::PubsubV1::PullRequest.new(max_messages: 1, return_immediately: false))
    ret.received_messages || []
  rescue Google::Apis::TransmissionError
    $stderr.puts $!
    []
  end

  def ack(subscription, msgs)
    msgs = [msg] unless msgs.is_a?(Array)
    return if msgs.empty?
    ack_ids = msgs.map(&:ack_id)
    @api.acknowledge_subscription(subscription, Google::Apis::PubsubV1::AcknowledgeRequest.new(ack_ids: ack_ids))
  end
end

class GCS
  def initialize
    @api = Google::Apis::StorageV1::StorageService.new
    @api.authorization = Google::Auth.get_application_default(["https://www.googleapis.com/auth/cloud-platform"])
    @api.authorization.fetch_access_token!
  end

  def insert_object(bucket, name, io, content_type: "image/jpeg")
    obj = Google::Apis::StorageV1::Object.new(name: name)
    @api.insert_object(bucket, obj, upload_source: io, content_type: content_type)
  end
end

class Blocks
  def initialize(url, token)
    @url = URI(url)
    @token = token
  end

  def invoke(params)
    res = Net::HTTP.post_form(@url, params)
    if res.code != "200"
      $stderr.puts("BLOCKS flow invocation failed: #{res.code} #{res.body}")
    end
  end
end

class CloudIot
  def initialize
    # use default credential
    @api = Google::Apis::CloudiotV1::CloudIotService.new
    @api.authorization = Google::Auth.get_application_default(["https://www.googleapis.com/auth/cloud-platform"])
    @api.authorization.fetch_access_token!
  end

  def list_device_configs(project, location, registry, device)
    @api.list_project_location_registry_device_config_versions("projects/#{project}/locations/#{location}/registries/#{registry}/devices/#{device}").device_configs
  end

  def modify_device_config(project, location, registry, device, str)
    @api.modify_cloud_to_device_config("projects/#{project}/locations/#{location}/registries/#{registry}/devices/#{device}",
                                       Google::Apis::CloudiotV1::ModifyCloudToDeviceConfigRequest.new(binary_data: str))
  end
end

module ML
  module_function
  def predict(project, model, instances)
    auth = Google::Auth.get_application_default(["https://www.googleapis.com/auth/cloud-platform"])
    auth.fetch_access_token!
    access_token =  auth.access_token
    uri = URI("https://ml.googleapis.com/v1/projects/#{project}/models/#{model}:predict")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Post.new(uri.request_uri)
    req["content-type"] = "application/json"
    req["Authorization"] = "Bearer #{access_token}"
    req.body = JSON.generate({ "instances" => instances })
    res = http.request(req)
    begin
      jobj = JSON.parse(res.body)
    rescue
      $stderr.puts "ERR: #{$!}"
      return nil
    end
    if jobj["error"]
      $stderr.puts "ERR: #{project}/#{model} #{jobj["error"]}"
      return nil
    end
    jobj["predictions"]
  end
end

LABELS = {
  1 => "person",
  2 => "bicycle",
  3 => "car",
  4 => "motorcycle",
  5 => "airplane",
  6 => "bus",
  7 => "train",
  8 => "truck",
  9 => "boat",
  10 => "traffic light",
  11 => "fire hydrant",
  13 => "stop sign",
  14 => "parking meter",
  15 => "bench",
  16 => "bird",
  17 => "cat",
  18 => "dog",
  19 => "horse",
  20 => "sheep",
  21 => "cow",
  22 => "elephant",
  23 => "bear",
  24 => "zebra",
  25 => "giraffe",
  27 => "backpack",
  28 => "umbrella",
  31 => "handbag",
  32 => "tie",
  33 => "suitcase",
  34 => "frisbee",
  35 => "skis",
  36 => "snowboard",
  37 => "sports ball",
  38 => "kite",
  39 => "baseball bat",
  40 => "baseball glove",
  41 => "skateboard",
  42 => "surfboard",
  43 => "tennis racket",
  44 => "bottle",
  46 => "wine glass",
  47 => "cup",
  48 => "fork",
  49 => "knife",
  50 => "spoon",
  51 => "bowl",
  52 => "banana",
  53 => "apple",
  54 => "sandwich",
  55 => "orange",
  56 => "broccoli",
  57 => "carrot",
  58 => "hot dog",
  59 => "pizza",
  60 => "donut",
  61 => "cake",
  62 => "chair",
  63 => "couch",
  64 => "potted plant",
  65 => "bed",
  67 => "dining table",
  70 => "toilet",
  72 => "tv",
  73 => "laptop",
  74 => "mouse",
  75 => "remote",
  76 => "keyboard",
  77 => "cell phone",
  78 => "microwave",
  79 => "oven",
  80 => "toaster",
  81 => "sink",
  82 => "refrigerator",
  84 => "book",
  85 => "clock",
  86 => "vase",
  87 => "scissors",
  88 => "teddy bear",
  89 => "hair drier",
  90 => "toothbrush",
}

def labels_to_url(detections)
  if detections.find{|label, score| label == "apple" }
    "https://storage.googleapis.com/gcp-iost-contents/apple-pie.jpg"
  elsif detections.find{|label, score| label == "banana" }
    "https://storage.googleapis.com/gcp-iost-contents/banana-cereal.jpg"
  else
    "https://storage.googleapis.com/gcp-iost-contents/pizza2.jpg"
  end
end

def main(config)
  project = config["project"]
  input_subscription = config["input_subscription"]
  bucket = config["bucket"]
  blocks_url = config["blocks_url"]
  blocks_token = config["blocks_token"]
  ml_model = config["ml_model"]
  iot_registry = config["iot_registry"]
  $stdout.puts "PubSub:#{input_subscription} -> ML Engine -> GCS(gs://#{bucket}/) & BigQuery"
  $stdout.puts "project = #{project}"
  $stdout.puts "subscription = #{input_subscription}"
  $stdout.puts "bucket = #{bucket}"
  $stdout.puts "blocks_url = #{blocks_url}"
  $stdout.puts "blocks_token = #{blocks_token.gsub(/./, "*")}"
  $stdout.puts "ml_model = #{ml_model}"
  $stdout.puts "iot_registry = #{iot_registry}"
  pubsub = Pubsub.new
  gcs = GCS.new
  iot = CloudIot.new
  blocks = Blocks.new(blocks_url, blocks_token)

  loop do
    msgs = pubsub.pull(input_subscription)
    $stdout.puts "#{msgs.size} messages pulled."
    next if msgs.empty?
    msgs.each do |m|
      device = m.message.attributes["deviceId"]
      time = Time.parse(m.message.publish_time)
      obj_name = time.strftime("original/#{device}/%Y-%m-%d/%H/%M%S.jpg")
      gcs.insert_object(bucket, obj_name, StringIO.new(m.message.data))
      annotated_name = time.strftime("annotated/#{device}/%Y-%m-%d/%H/%M%S.jpg")
      blocks.invoke({
        api_token: blocks_token,
        published_time: time.iso8601(3),
        device: device,
        original_gcs: "gs://#{bucket}/#{obj_name}",
        annotated_gcs: "gs://#{bucket}/#{annotated_name}",
      })
      # Load Device config
      last_config = iot.list_device_configs(project, "us-central1", iot_registry, device).first
      data = JSON.parse(last_config.binary_data)
      # Object Detection prediction
      pred = ML.predict(project, ml_model, [{"key" => "1", "image" => { "b64" => Base64.strict_encode64(m.message.data) } }])
      objs = pred[0]["detection_classes"].zip(pred[0]["detection_scores"]).select{|label, score| score > 0.2}.map{|label, score| [LABELS[label.to_i], score] }
      $stdout.puts(objs.inspect)
      url = labels_to_url(objs)
      if data["dashboard_url"] != url and Time.parse(last_config.cloud_update_time) + 20 < Time.now
        $stdout.puts("URL change : #{url}")
        data["dashboard_url"] = url
        iot.modify_device_config(project, "us-central1", iot_registry, device, data.to_json)
      end
    end
    pubsub.ack(input_subscription, msgs)
  end
end

if $0 == __FILE__
  config, = ARGV

  if config
    config = YAML.load(File.read(config))
    config["input_subscription"] = "projects/#{config["project"]}/subscriptions/#{config["input_subscription"]}"
  else
    config = {}
    config["project"] = ENV["PROJECT"]
    config["input_subscription"] = "projects/#{config["project"]}/subscriptions/#{ENV["INPUT_SUBSCRIPTION"]}"
    config["bucket"] = ENV["SAVE_BUCKET"]
    config["blocks_url"] = ENV["BLOCKS_URL"]
    config["blocks_token"] = ENV["BLOCKS_TOKEN"]
    config["ml_model"] = ENV["ML_MODEL"]
    config["iot_registry"] = ENV["IOT_REGISTRY"]
  end
  $stdout.sync = true
  $stderr.sync = true
  main(config)
end
