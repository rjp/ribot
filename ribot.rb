require 'rubygems'
require 'xmpp4r'
require 'xmpp4r/muc/helper/simplemucclient'
include Jabber
require 'thread'

require 'uri-find'
require 'meta-title'

$bot = nil
threads = {}
$options = { :myjid => 'mucg@localhost/bot', :mypass => 'test', :whoto => 'fish@muc.localhost/bot' }

q_urls = Queue.new
q_meta = Queue.new

threads['muc'] = Thread.new {
    cl = Jabber::Client.new(Jabber::JID.new($options[:myjid]))
    cl.connect('localhost')
    cl.auth($options[:mypass])
    m = Jabber::MUC::SimpleMUCClient.new(cl)
    m.add_message_callback do |msg|
        if msg.type == :groupchat and msg.from != $options[:whoto] then
            print "+ #{msg.from} #{msg.body}\n"
            urls = rule(msg.body, 'http')
            urls.each do |url|
	            # look for any urls, enqueue them onto q_urls
                print "MUC enqueuing [#{url}]\n"
	            q_urls.enq [msg.from, url]
            end
        end
    end
    m.join($options[:whoto])
    Thread.current['bot'] = m
}

threads['meta'] = Thread.new {
    i = 0
    loop do
        print "MTA waiting for an item\n"
        obj = q_urls.deq
        puts "meta for " + obj.join(', ') + " b=#{$bot}"
        a = Thread.new { 
            t = title_from_uri(obj[1])
            threads['muc']['bot'].say "#{i} #{t}"
        }
        print "MTA incrementing and relooping\n"
        i = i + 1
    end
}

threads['muc'].join
threads['meta'].join
