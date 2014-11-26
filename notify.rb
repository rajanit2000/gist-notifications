require 'uri'
require 'net/http'
require 'net/https'
require 'json'
require 'date'
require 'erb'
require 'net/smtp'

class RunDetails

  attr_reader :username

  def initializelast_run_time_file_location
    @this_run_time = DateTime.now
    @last_run_time_file_location = last_run_time_file_location
  end

  def last_run_time
    @last_run_time ||= begin
      if File.exist?(last_run_time_file_location)
        DateTime.parse(File.read(last_run_time_file_location))
      else
        DateTime.now - 1
      end
    end
  end

  def update_last_run_time
    File.open(last_run_time_file_location, "w") { |file| file << this_run_time.xmlschema }
  end

  private

  attr_reader :last_run_time_file_location, :this_run_time

end

class GistRepository

  def gists_with_comments_updated_since username, last_run_time
    get_gists_with_comments(username)
      .select{ | gist | gist.any_comments_created_or_updated_since? last_run_time }
  end

  private

  def make_request url
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    request = Net::HTTP::Get.new(uri.request_uri)
    request['Accept'] = 'application/vnd.github.v3+json'
    response = http.request(request)
    if response.code == '200'
      JSON.parse(response.body)
    else
      raise "Error response #{response.code} #{response.body}"
    end
  end

  def get_gists_for_user username
    make_request("https://api.github.com/users/#{username}/gists")
      .collect { |gist| Gist.new(gist) }
  end

  def add_comments gists
    gists.select(&:has_comments?).collect do | gist |
      sleep 3
      gist.comments = get_comments(gist)
      gist
    end
  end

  def get_gists_with_comments username
    add_comments(get_gists_for_user(username))
  end


  def get_comments gist
    make_request gist.comments_url
  end
end


class Gist

  def initialize attributes
    @attributes = attributes
    @comments = []
  end

  def description
    attributes["description"]
  end

  def comments_url
    attributes['comments_url']
  end

  def has_comments?
    attributes["comments"] > 0
  end

  def comments= comments
    @comments = comments
  end

  def html_url
    @attributes['html_url']
  end

  def to_json options = {}
    to_hash.to_json options
  end

  def to_hash
    {
      "url" => attributes["url"],
      "description" => attributes["description"],
      "comments" => comments
    }
  end

  def any_comments_created_or_updated_since? datetime
    comments_created_or_updated_since(datetime).any?
  end

  def comments_created_or_updated_since datetime
    comments.select do | comment |
      DateTime.parse(comment["updated_at"]) >= datetime
    end
  end

  private

  attr_reader :attributes, :comments

end

class NotificationEmail

  attr_reader :recipient, :sender, :sender_password, :smtp_server

  def initialize recipient, sender, sender_password, smtp_server
    @recipient = recipient
    @sender = sender
    @sender_password = sender_password
    @smtp_server = smtp_server
  end

  def send msg
    msg = "Subject: New comments on gists\n\n#{msg}"
    smtp = Net::SMTP.new smtp_server, 587
    smtp.enable_starttls

    smtp.start(sender.split("@").last, sender, sender_password, :login) do
      smtp.send_message(msg, sender, recipient)
    end
  end

end

username = ARGV[0]
recipient = ARGV[1]
sender = ARGV[2]
sender_password = ARGV[3]
smtp_server = ARGV[4] || 'smtp.gmail.com'
last_run_time_file_location = ARGV[5] || "/tmp/gist-notifications-last-run-time"

run_details = RunDetails.new(last_run_time_file_location)
gists = GistRepository.new.gists_with_comments_updated_since(username, run_details.last_run_time)
run_details.update_last_run_time
puts "#{gists.size} updated since #{run_details.last_run_time}"
if gists.any?
  renderer = ERB.new(DATA.read)
  notification_body = renderer.result(binding())
  puts notification_body
  NotificationEmail.new(recipient, sender, sender_password, smtp_server).send notification_body
end

__END__
<% gists.each do | gist | %>
  <%= gist.description %>
  <%= gist.html_url %>
    <% gist.comments_created_or_updated_since(run_details.last_run_time).each do | comment | %>
      <%= comment['user']['login'] %> said:
      <%= comment['body'] %>
    <% end %>
<% end %>
