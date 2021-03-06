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

# required for nice handling of unicode
$KCODE='u'

# we use transactions for safe fetching of last-insert-id things
$dbh = DBI.connect($options[:dsn], '', '')
$dbh['AutoCommit'] = false

$get_last_id = nil
$now = nil

# sketchy multi-database support
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

# incoming queue of URLs to find information about
$q_urls = Queue.new
# outgoing queue of things for the bot to say
$q_meta = Queue.new

# TODO move this to its own library?
def deli_tags(uri, id)
    begin
        md5 = Digest::MD5.hexdigest(uri)
        target = "http://badges.del.icio.us/feeds/json/url/data?hash=#{md5}"
        json = open(target).read
        deli = JSON.load(json)[0]
        tags = ""
        if deli['top_tags'].class == Hash then
            all_tags = deli['top_tags'].sort_by {|k,v| v}.reverse.map{|i|i[0]}
            if all_tags.size > 8 then
                all_tags = all_tags.first(8) << '...'
            end
            tags = '(' << all_tags.join(', ') << ')'
        end
        if deli['total_posts'].to_i > 0 then
            response = "#{id}: (deli) #{deli['total_posts']} links, tagged #{tags}"
            $q_meta.enq response
        end
    rescue
        puts "problem fetching deli for #{uri}"
    end
end

$threads['muc'] = Thread.new {
    cl = Jabber::Client.new(Jabber::JID.new($options[:myjid]))
    cl.connect($options[:xmpphost])
    cl.auth($options[:mypass])
    m = Jabber::MUC::SimpleMUCClient.new(cl)
    m.add_message_callback do |msg|
        old = nil
        # sucks that we have to implement this ourselves
        msg.each_element('x') { |x|
          if x.kind_of?(Delay::XDelay)
            old = 1
          end
        }

        if  old.nil?                      # not historical lines
        and msg.type == :groupchat        # comes from the conference
        and msg.from != $options[:whoto]  # we didn't say it
        and not msg.body.nil? then        # something was said (not a topic change)
            print "+ #{msg.from} #{msg.body}\n"
            urls = rule(msg.body, ['http', 'https'])
            urls.each do |url|
                # look for any urls, enqueue them onto $q_urls
                print "MUC enqueuing [#{url[0]}]\n"
                $q_urls.enq [msg.from, url]
            end
        end
    end
    m.join($options[:whoto])
    Thread.current['bot'] = m
}

# separate thread for things going back to the conference
$threads['muc_say'] = Thread.new {
    loop do
        bot_says = $q_meta.deq
        puts "something to say!"
        $threads['muc']['bot'].say bot_says
    end
}

# used to decode any HTML entities in the title into Unicode
$coder = HTMLEntities.new

# all the work of processing a URL happens in this thread
$threads['meta'] = Thread.new {
    i = 0
    loop do
        print "MTA waiting for an item\n"
        obj = $q_urls.deq
        puts "meta for " + obj.join(', ') + " b=#{$bot}"
        # spawn off a new thread to handle the fetching to avoid blocking
        a = Thread.new {
            begin
            myobj = obj.dup
            puts "fetching title for #{myobj[1][0]}"
            t, supress_domain = title_from_uri(myobj[1][0])
            puts "fetched title for #{myobj[1][0]}"
            last_id = nil
            # insert the URL and get the inserted ID
            $dbh.transaction do
                $dbh.do(
                    "INSERT INTO url (url, wh, byuser, private, title)
                     VALUES (?, #{$now}, ?, ?, ?)",
                    myobj[1][0], myobj[0].to_s, 0, t
                )
                last_id = $dbh.select_one($get_last_id)
            end
            my_id = last_id[0]
            # last 3 parts of the hostname should be unambiguous
            domain = obj[1][1].host.split('.').last(3).join('.')
            # default formatting is stolen from old scribot
            # 16:24 < scribot> 67041: [www.youtube.com]: vs (YouTube - Maya The Tamperer (Can You Feel It))
            response = "#{my_id}: [#{domain}]: #{t}"
            # plugins can suppress the domain information because it's often unnecessary
            # 12345: (flickr) "photo title" by photo maker
            if supress_domain then
                response = "#{my_id}: #{t}"
            end
            # people like guardian.co.uk insist on putting newlines in the title
            response.gsub!("\n", ' ')
            # decode the HTML entities and queue this for the bot to say
            $q_meta.enq $coder.decode(response)
            # do the deli tagging in another thread
            b = Thread.new {
                deli_tags(myobj[1][0], last_id)
            }
            rescue
                puts "problem getting information for #{myobj[1][0]}"
            end
        }
        print "MTA incrementing and relooping\n"
        i = i + 1
    end
}

$threads['muc'].join
$threads['meta'].join
