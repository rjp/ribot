require 'rubygems'
require 'xmpp4r'
require 'xmpp4r/muc/helper/simplemucclient'
include Jabber
require 'thread'
require 'dbi'
require 'uri-find'
require 'meta-title'

$dbh = DBI.connect('DBI:sqlite3:/home/rjp/.ribot.db', '', '')
$dbh['AutoCommit'] = false

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
        old = nil
        msg.each_element('x') { |x|
          if x.kind_of?(Delay::XDelay)
            old = 1
          end
        }

        if old.nil? and msg.type == :groupchat and msg.from != $options[:whoto] then
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

threads['meta'] = Thread.new {
    i = 0
    loop do
        print "MTA waiting for an item\n"
        obj = q_urls.deq
        puts "meta for " + obj.join(', ') + " b=#{$bot}"
        a = Thread.new {
            myobj = obj.dup
            t = title_from_uri(myobj[1][0])
# CREATE TABLE urls (id INTEGER PRIMARY KEY AUTOINCREMENT, url varchar(1024), wh timestamp, user varchar(256), private int, title varchar(1024));
            last_id = nil
            $dbh.transaction do
                $dbh.do(
                    "INSERT INTO urls (url, wh, user, private, title)
                     VALUES (?, DATETIME('NOW'), ?, ?, ?)",
                    myobj[1][0], myobj[0], 0, t
                )
                last_id = $dbh.select_one(
                    "SELECT last_insert_rowid()"
                )
            end
            my_id = last_id[0]
            domain = obj[1][1].host.split('.')[-3..-1].join('.')
## 16:24 < scribot> 67041: [www.youtube.com]: vs (YouTube - Maya The Tamperer (Can You Feel It))
            response = "#{my_id}: [#{domain}]: #{t}"
            threads['muc']['bot'].say response
        }
        print "MTA incrementing and relooping\n"
        i = i + 1
    end
}

threads['muc'].join
threads['meta'].join
