require 'rubygems'
require 'xmpp4r'
require 'xmpp4r/muc/helper/simplemucclient'
include Jabber
require 'thread'

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
            puts "+ #{msg.from} #{msg.body}"
            # look for any urls, enqueue them onto q_urls
            q_urls.enq [msg.from, msg.body]
        end
    end
    m.join($options[:whoto])
    m.say "HELLO SIR!"
    Thread.current['bot'] = m
}

threads['meta'] = Thread.new {
    i = 0
    loop do
        print "MT waiting for an item\n"
        obj = q_urls.deq
        puts "meta for " + obj.join(', ') + " b=#{$bot}"
        a = Thread.new { 
            print "NT sleeping for 5\n"
            sleep(5)
            print "NT reporting\n"
            threads['muc']['bot'].say "monkey #{i} #{obj[1]}"
        }
        print "MT incrementing and relooping\n"
        i = i + 1
    end
}

threads['muc'].join
threads['meta'].join
