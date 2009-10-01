require 'rubygems'
require 'xmpp4r'
require 'xmpp4r/muc/helper/simplemucclient'
include Jabber
require 'thread'
require 'dbi'
require 'uri-find'
require 'meta-title'
require 'htmlentities'
require 'trollop'
require 'yaml'
require 'json'

$options = Trollop::options do
    opt :myjid, "My JID", :type => :string
    opt :mypass, "My Pass", :type => :string
    opt :whoto, "Target MUC", :type => :string
    opt :config, "Config file", :default => ENV['HOME']+'/.ribot'
    opt :xmpphost, "XMPP host", :type => :string
end

begin
	config = YAML::load(open($options[:config]))

	# merge the whole of the config file into the $options hash
	config.each { |k,v|
	    $options[k.to_sym] = v if $options[k.to_sym].nil?
	}
rescue => e
end


p $options

$KCODE='u'

$dbh = DBI.connect($options[:dsn], '', '')
$dbh['AutoCommit'] = false

$get_last_id = nil
$now = nil

case $options[:dsn]
    when /sqlite/i
        $get_last_id = "SELECT last_insert_rowid()"
        $now = "DATETIME('NOW')"
    when /pg/i
        $get_last_id = "SELECT CURRVAL('url_seq')"
        $now = "NOW()"
end
p $get_last_id

$bot = nil
$threads = {}

# TODO move this to its own library
def deli_tags(uri, id)
    md5 = Digest::MD5.hexdigest(uri)
    target = "http://badges.del.icio.us/feeds/json/url/data?hash=#{md5}"
    json = open(target).read
    deli = JSON.load(json)[0]
    tags = ""
    if deli['top_tags'].class == Hash then
        tags = '((' << deli['top_tags'].sort_by {|k,v| v}.reverse.map{|i|i[0]}.join(', ') << '))'
    end
    response = "#{id}: (deli) L=#{deli['total_posts']} #{tags}"
    $threads['muc']['bot'].say response
end


q_urls = Queue.new
q_meta = Queue.new

$threads['muc'] = Thread.new {
    cl = Jabber::Client.new(Jabber::JID.new($options[:myjid]))
    cl.connect($options[:xmpphost])
    cl.auth($options[:mypass])
    m = Jabber::MUC::SimpleMUCClient.new(cl)
    m.add_message_callback do |msg|
        old = nil
        msg.each_element('x') { |x|
          if x.kind_of?(Delay::XDelay)
            old = 1
          end
        }

        if old.nil? and msg.type == :groupchat and msg.from != $options[:whoto] and not msg.body.nil? then
            print "+ #{msg.from} #{msg.body}\n"
            urls = rule(msg.body, 'http')
            urls.each do |url|
                # look for any urls, enqueue them onto q_urls
                print "MUC enqueuing [#{url[0]}]\n"
                q_urls.enq [msg.from, url]
            end
        end
    end
    m.join($options[:whoto])
    Thread.current['bot'] = m
}

$coder = HTMLEntities.new
$threads['meta'] = Thread.new {
    i = 0
    loop do
        print "MTA waiting for an item\n"
        obj = q_urls.deq
        puts "meta for " + obj.join(', ') + " b=#{$bot}"
        a = Thread.new {
            myobj = obj.dup
            puts "fetching title for #{myobj[1][0]}"
            begin
            t, supress_domain = title_from_uri(myobj[1][0])
            rescue => e
            puts e
            Thread.exit
            end
            puts "fetched title for #{myobj[1][0]}"
# CREATE TABLE urls (id INTEGER PRIMARY KEY AUTOINCREMENT, url varchar(1024), wh timestamp, user varchar(256), private int, title varchar(1024));
            last_id = nil
            $dbh.transaction do
                $dbh.do(
                    "INSERT INTO url (url, wh, byuser, private, title)
                     VALUES (?, #{$now}, ?, ?, ?)",
                    myobj[1][0], myobj[0].to_s, 0, t
                )
                last_id = $dbh.select_one($get_last_id)
            end
            puts "inserted into database"
            my_id = last_id[0]
            domain = obj[1][1].host.split('.').last(3).join('.')
## 16:24 < scribot> 67041: [www.youtube.com]: vs (YouTube - Maya The Tamperer (Can You Feel It))
puts "making response"
            response = "#{my_id}: [#{domain}]: #{t}"
            if supress_domain then
                response = "#{my_id}: #{t}"
            end
            response.gsub!("\n", ' ')
puts "sending response"
            $threads['muc']['bot'].say $coder.decode(response)
# do the deli tagging in another thread
            b = Thread.new {
                puts "deli requesting"
                deli_tags(myobj[1][0], last_id)
            }
        }
        print "MTA incrementing and relooping\n"
        i = i + 1
    end
}

$threads['muc'].join
$threads['meta'].join
