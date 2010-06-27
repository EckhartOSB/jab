require "rubygems"
require "readline"
require "xmpp4r/client"
require "xmpp4r/roster"
include Jabber

class Jab

  VERSION = "0.2"
  AUTHOR = "Chip Camden"
  SITE = "http://chipstips.com/?tag=rbjab"

  def initialize
    #Jabber::debug = true
    @requests = []			# pending subscription requests
    @colors = []			# color substitutions to apply
    @notify = {:errors => true, :info => true, :jabs => true, :status => true, :always => true}
    					# all notifications on by default
    @accept = :ask			# prompt for subscriptions by default
    @sandbox = (Proc.new {}).binding	# safe place for userboy to play
    @pager = ENV['PAGER'] || 'less'	# pager for help
  end

  # if you forget to quote something, maybe we can do it for you.
  def method_missing(sym, *args)
    args.unshift(sym.to_s).join(' ')
  end

  # ask the user for input, with a stylized prompt
  # silent turns off echo if stty is available
  # call is the caller to report, in `' - a string
  #  that doesn't contain `' will not indicate a caller,
  #  but nil will use the caller of this function.
  def ask(prompt, silent=nil, call=nil)
    system 'stty -echo' if silent && $stdin.isatty
    /.*`(.*)'/ =~ (call ? call : caller[0])
    p = $1 ? "(#{$1}) #{prompt}: " : "#{prompt}: "
    @colors.each do |cla|
      p.gsub! *cla
    end
    res = $stdin.isatty ? Readline.readline(p, true) : $stdin.gets
    system('stty echo') && puts('') if silent && $stdin.isatty
    res ? res.chomp : res
  end

  # ask a multiple-choice question.
  # choices: array of possible answers
  # default: which one to choose if the user presses RETURN
  # call: same as for ask
  def multiask(choices, default=nil, call=nil)
     Readline.completion_append_character = nil
     Readline.completion_proc = proc {|s| choices.grep(/^#{Regexp.escape(s)}/) }
     r = ''
     begin
       prompt = choices.join('/')
       prompt.sub!(/\b#{default}\b/, "[#{default}]") if default
       r = ask(prompt, nil, (call ? call : caller[0]))
       r = default if default && r && (r == '')
     end until (!r || choices.include?(r))
     r
  end

  # display something to the user, applying any coloring filters
  def say(what)
    s = what
    @colors.each do |cla|
      s.gsub! *cla
    end
    print s
  end

  # stylized messages from jab, filtered by @notify
  def interject(type, sender, msg)
    say ">#{sender || ''} #{msg}\n" if @notify[type]
  end

  # connect to an XMPP server
  def connect(user=nil, password=nil)
    id = user || ask("user@domain/resource")
    if id
      pw = password || ask("password", true)
      if pw
	say ">connecting..." if @notify[:info]
	$stdout.flush
	jid = JID::new id
	@client = Client::new jid
	@client.connect
	@client.auth pw
	@user = user

	# when we receive a message...
	@client.add_message_callback do |m|
	  case m.type
	    when :chat || :normal
	      if m.body
		interject :jabs, m.from, 'jabs: ' + m.body
	      end
	    when :error
	      interject :errors, m.from, 'ducked your jab:' + m.to_s.gsub(/<\/\w+>/,'').gsub(/\/?>/,'').gsub(/</,"\n>").gsub(/xmlns=(['"]).+?\1/,'')
	  end
	end
	@roster = Roster::Helper.new @client
	# when we're asked to subscribe...
	@roster.add_subscription_request_callback do |item,pres|
	  case @accept
	    when :ask
	      @requests << pres		# Save it for later, in case we're already processing user input
	    when :y
	      @roster.accept_subscription pres.from
	      tap pres.from
	      interject :status, pres.from, "can now jab you"
	    when :n
	      @roster.decline_subscription pres.from
	      interject :status, pres.from, "denied"
	  end
	end
	# notification of [un]subscription (haven't seen any of these yet, though)
	@roster.add_subscription_callback do |roster,pres|
	  case pres.type
	    when :subscribed
	      interject :status, pres.from, "is now jabbable"
	    when :unsubscribed
	      interject :status, pres.from, "can no longer be jabbed"
	  end
	end
	# notification of status change
	@roster.add_presence_callback do |roster, old, new|
	  interject :status, new.from, 'is ' + (new.show ? new.show.to_s : 'available') + (new.status ? ': ' + new.status : '')
	end
	say "done.\n" if @notify[:info]
	true
      else
	false
      end
    else
      false
    end
  end

  # deferred subscription requests, handled between commands
  def handle_requests
    while pres = @requests.shift
      interject :always, pres.from, "wants to be able to jab you.\n>the question is, do you want to be jabbed? "
      ans = multiask(['y','n'], nil, '')
      if ans && (ans == 'y')
	interject :info, pres.from, "-- come on in!"
	@roster.accept_subscription pres.from
	tap pres.from
      else
	interject :info, pres.from, "-- rejected!"
	@roster.decline_subscription pres.from
      end
    end
    true
  end

  # send message(s)
  def jab(user=nil, message=nil)
    who = user || ask("whom")
    if who
      if message
	m = Message::new who, message
	m.type = :chat
	@client.send m
      else		# unlike other commands, we'll keep jabbing until EOF
	while msg = ask(who)
	  if msg.length > 0
	    m = Message::new who, msg
	    m.type = :chat
	    @client.send m
	  end
	end
	puts ''
      end
    end
    nil
  end

  # request subscription or status
  def tap(user=nil)
    who = user || ask("whom")
    @client.send Presence.new.set_type(:subscribe).set_to(who) if who
  end

  # request unsubscription
  def shove(user=nil)
    who = user || ask("whom")
    @client.send Presence.new.set_type(:unsubscribe).set_to(who) if who
  end

  # change our status
  def status(sts=nil, msg=nil)
    s = sts || multiask(['away','chat','dnd','xa'], 'chat')
    if s
      pres = Presence.new
      pres.show = s.to_sym
      pres.status = msg || ask("message [none]")
      if pres.status
	@client.send pres
	@presence = pres		# for later reporting
      end
    end
  end

  # report current settings
  def settings
    interject :always, @user, "status :" + (@presence ?
      @presence.show.to_s + (@presence.status ? ", '#{@presence.status}'" : '') :
      "unknown")
    @notify.each do |what, onoff|
      interject :always, @user, "hush :#{what.to_s}" if !onoff
    end
    interject :always, @user, "when_tapped :#{@accept.to_s}"
  end

  # change our notification preferences
  def notify(what, on)
    w = what || multiask(['all','errors','info','jabs','status'], nil, caller[0])
    if w
      w = w.to_sym
      if w == :all
	@notify[:errors] = on
	@notify[:info] = on
	@notify[:jabs] = on
	@notify[:status] = on
      else
	@notify[w] = on
      end
    end
  end

  # turn off notifications
  def hush(what=nil)
    notify(what, false)
  end

  # turn them back on
  def unhush(what=nil)
    notify(what, true)
  end

  # preference for handling subscription requests
  def when_tapped(action=nil)
    a = action || multiask(['ask','n','y'], 'ask')
    @accept = a.to_sym if a
  end

  # process commands from a file
  def source(file=nil, ignore_fnf=nil)
    f = file || ask("filename")
    if f
      f = File.expand_path(f)
      if (!ignore_fnf) || (File.exists? f)
	begin
	  File.open f do |fd|
	    eval fd.readlines.join, @sandbox, file
	  end
	rescue Exception => exc
	  interject :errors, nil, "error in #{file}\n>#{$!}"
	end
      end
    end
  end

  # internal routine for retrieving a termcap sequence for setting a color
  def get_color(cap, c)
     cn = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white", "grey"].index(c.to_s.downcase) || c.to_i
     @@numcolors ||= `tput Co`.to_i
     raise "color #{cn} not supported by terminal" if cn >= @@numcolors
     `tput #{cap} #{cn}`
  end

  # sequence for setting foreground
  def fg(c)
     get_color('AF',c) if c
  end

  # sequence for setting background
  def bg(c)
     get_color('AB',c) if c
  end

  # add a color filter
  # what can be a string, but will be treated as a Regexp
  # how is zero or more escape sequences, most likely returned by fg or bg
  def color(what,*how)
    if how.size > 0
      @@op ||= `tput op`
      @colors << [Regexp.new(what), how.join('') + '\0' + @@op]
    end
  end

  def about
    say "jab version #{VERSION}, by #{AUTHOR}\n"
    say "site: #{SITE}\n"
  end

  def help
    File.popen(@pager, 'w') do |p|
      p.print <<END
jab version #{VERSION}, by #{AUTHOR}
site: #{SITE}

commands:

about						information about jab
color pattern, [sequence...]			prefix pattern with sequence
connect ["user@domain/resource"], ["password"]	connect to XMPP server
help						print this list
hush [type]					suppress certain messages
jab [user], [message]				send a message
q						exit
settings					display current settings
shove [user]					unsubscribe from user
source [file], [ignore_fnf]			read file for commands
status [sts], [message]				set availability status
tap [user]					request subscription or status
unhush [type]					allow certain messages
when_tapped [action]				how to handle sub requests
<eof>						exit

Most optional parameters not supplied will be requested.  Additionally,
you can use any Ruby statements, which will be executed within a
sandboxed binding.  Thus, for example, to establish a user alias:

chip = "sterlingcamden@jabber.org"

which creates the variable chip in the sandboxed context.  Now you can:

jab chip

If the file ~/.jabrc exists, it will be evaluated prior to asking you
for commands.  You can override this file by using the -r command line
switch.  See the README.

If an identifier is not recognized, it will be converted into its string
equivalent.  Thus, by default, red = "red".

Autocompletion is enabled when asked a multiple-choice question.  Just
press Tab.  Line editing mode is vi by default, but you can specify emacs
with the -e command line switch.

Sequences for the color command can be generated from termcap using the
addtional commands 'fg' and 'bg', which each take a color name or number
as an argument.  The only names recognized are "black", "red", "green",
"blue", "magenta", "cyan", "white", and "grey" -- but you can pass any
color number that is supported by the termcap entry for your terminal
type.  This capability relies on being able to execute 'tput'.

Examples:

color /^:/ , fg(blue)					# prompt blue
color /^>.*ducked your jab:.*/ , bg(red), fg(white)	# flag errors
color /^>\#{chip}\\S* jabs:.*/m , fg(226)			# jabs from chip
color /^>\\S* is .*/ , fg(grey)				# status changes

END
    end
  end

  def q
    exit
  end

  # accept a command from the user, trapping interrupt
  def getcmd
    ask('', false, '')
  rescue Interrupt => exc
    interject :errors, nil, "interrupted"
    ''
  end

  # your basic read/eval loop, with the additional synchronized
  # handling of asynchronous requests
  def interact
    while (@client || connect) && handle_requests && (cmd = getcmd)
      begin
	eval cmd, @sandbox
      rescue SystemExit => exc
	break
      rescue Exception => exc
	interject :errors, nil, "error evaluating command '#{cmd}'\n>#{$!}"
      end
    end
  end

end	# class Jab
