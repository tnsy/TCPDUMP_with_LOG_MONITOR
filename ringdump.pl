#!/usr/bin/perl
## VERSION v1.0
## Modified by Aleksei Kozadev to run on v10.x and above as well as include full noise
## VERSION v1.0.1
## Modified by Julius Jairos to dump on all vlans using interface "any" which is "0.0" and also to run on any platform (Viprion,VE,vCMP,Appliance).
## Also added modifier "p" to capture internal monitor flow between bigd/host and tmm.
## VERSION v1.0.2
## Modified by Julius Jairos eliminate the need to edit the file for setting parameters, now users get prompted for parameters.

use strict;

### Settings required to get the captures.
# Get the desired vlan
print "Enter the desired vlan else enter \"any\" to capture on all vlans:\n";
my $VLAN = <STDIN>;
chomp $VLAN;

# Get the desired packet capture filter.
print "\nEnter the desired packet capture filter e.g \(\(host 10.110.110.249 and host 10.100.100.50\) and port 80\):\n";
my $PCAPFILTER = <STDIN>;
chomp $PCAPFILTER;

# Get the relevant log message to stop the packet capture.
print "\nEnter the log message to stop the packet capture:\n";
my $LOG_MESSAGE = <STDIN>;
chomp $LOG_MESSAGE;

################
# tcpdump settings
##########

my %SETTINGS	= (
#		"any" => { filter => "(((host 10.110.110.249) and (host 10.100.100.50)) and (port 80))" },
		"$VLAN" => { filter => "$PCAPFILTER" },
);

my $SNAPLEN = 0;

################
# script settings
######

# free space checking
my $FREE_SPACE_CHECK_INTERVAL = 1;	# check free space every this number of seconds
my $MIN_FREE_SPACE            = 5;	# minimum percent space left on parition
my $CAPTURE_LOCATION          = $ARGV[0];

# file rotation settings
my $CAPTURES_TO_ROTATE        = 4;	# tcpdump capture files to rotate
my $DESIRED_CAPTURE_SIZE      = 15;	# megabytes per capture file before rotating
my $OVERLAP_DURING_ROTATE     = 5;	# seconds to overlap previous capture while starting a new one
my $CAPTURE_CHECK_INTERVAL    = 1;	# how often (seconds) to check the size of capture files for rotating

# trigger settings - time (run tcpdumps for x seconds)
#my $TRIGGER                  = "time-based";
my $TIME_TO_CAPTURE           = 300;

# trigger settings - log-message (stop tcpdump when log message is received)
my $TRIGGER                   = "log-message based";
my $LOG_FILE                  = "/var/log/ltm";
#my $LOG_MESSAGE               = "/Common/10.100.100.50:80 monitor status down";
my $FOUND_MESSAGE_WAIT        = 33;	# how many seconds to gather tcpdumps after we match the log message

# misc
my $IDLE_TIMER                = 5;      # if ! receiving log entries, how long before checking if log is rotated
my $MAX_ROTATED_LINES         = 10000;  # max lines to read from file we're re-reading because it's been rotated
my $PID_FILE                  = "/var/run/ring_pcap.pid";
my $DEBUG                     = 0;      # 0/1

#my $PREFIX                    = ":nnn";#This does not include internal flow between bigd/host and tmm
my $PREFIX                    = ":nnnp";#This includes internal between bigd/host and tmm as well as tmm and pool member

####################################################
# END OF THINGS THAT SHOULD NEED TO BE CONFIGURED
####################################################


########
# set defaults
###

$SNAPLEN                   ||= 0;
$TRIGGER                   ||= "time";
$CAPTURE_LOCATION          ||= "/var/tmp/captures";
$TIME_TO_CAPTURE           ||= 60;
$FREE_SPACE_CHECK_INTERVAL ||= 5;
$CAPTURES_TO_ROTATE        ||= 3;
$DESIRED_CAPTURE_SIZE      ||= 10;
$OVERLAP_DURING_ROTATE     ||= 5;
$CAPTURE_CHECK_INTERVAL    ||= 5;
$MIN_FREE_SPACE            ||= 5;
$LOG_FILE                  ||= "/var/log/ltm";
$LOG_MESSAGE               ||= "FAILED";
$FOUND_MESSAGE_WAIT        ||= 5;
$IDLE_TIMER                ||= 5;
$PID_FILE                  ||= "/var/run/ring_pcap.pid";
$DEBUG                     ||= 0;

unless (-d $CAPTURE_LOCATION) {
   print "$CAPTURE_LOCATION isn't a directory, using /mnt instead\n\n";
   $CAPTURE_LOCATION = "/mnt";
}

if (! -r $LOG_FILE) {
   die "Can't read \"$LOG_FILE\", EXIT\n";
}

# insert code to find tcpdump instead of relying on path HERE:

my $tcpdump = "/usr/sbin/tcpdump";


######
# misc global variable declaration
##########

my($answer, $interface, $pid, $tail_child, $F_LOG);
my($current_size, $current_inode, $last_size, $last_inode);

my @child_pids;
my $ppid          = $$;
my $min_megabytes = $CAPTURES_TO_ROTATE * $DESIRED_CAPTURE_SIZE;

$current_size = $current_inode = $last_size = $last_inode = 0;
$|++;

###########
# functions
#######

# exit function that does does necessary child handling

sub finish {
   $_ = shift();
   if (defined($_) && $_ ne "") {
	print;
   }

   foreach $interface (keys( %SETTINGS )) {
	push(@child_pids, $SETTINGS{$interface}{pid});
   }

   $DEBUG && print "INTERRUPT: sending SIGINT and SIGTERM to: ", join(" ", @child_pids), "\n";
   kill(2, @child_pids);
   sleep(1);
   kill(15, @child_pids);
   $DEBUG && print "INTERRUPT: done, unlink pidfile and exit\n";

   unlink($PID_FILE);
   exit(0);
}

$SIG{INT}  = sub { finish(); };


# report usage on CAPTURE_LOCATION's MB free from df

sub free_megabytes {
   my $partition = shift();
   $partition  ||= $CAPTURE_LOCATION;

   my $free_megabytes;

   $DEBUG && print "free_megabytes(): capture partition is $partition\n";

   open(DF, "df -P $partition|");

   # discard the first line;
   $_ = <DF>;

   # parse the usage out of the second line
   $_ = <DF>;
   $free_megabytes = (split)[3];
   $free_megabytes = int($free_megabytes / 1024);

   close(DF);

   $DEBUG && print "free_megabytes(): finished reading df, output is: $free_megabytes\n";

   $free_megabytes;
}

# report usage on CAPTURE_LOCATION's % usage from df

sub free_percent {
   my $partition = shift();
   $partition  ||= $CAPTURE_LOCATION;

   my $free_percent;

   $DEBUG && print "free_percent(): capture partition is $partition\n";

   open(DF, "df $partition|");

   # discard the first line;
   $_ = <DF>;

   # parse the usage out of the second line
   $_ = <DF>;
   $_ = <DF>;
   $free_percent = (split)[3];
   chop($free_percent);  ## chop off '%'
   $free_percent = (100 - $free_percent);

   close(DF);

   $DEBUG && print "free_percent(): finished reading df, output is: $free_percent\n";

   $free_percent;
}

# simple sub to send SIGHUP to syslogd

sub restart_syslogd () {
   if (-f "/var/run/syslog.pid") {
	open(PIDFILE, "</var/run/syslog.pid");
   } elsif (-f "/var/run/syslogd.pid") {
	open(PIDFILE, "</var/run/syslogd.pid");
   } elsif (-f "/var/run/syslog-ng.pid") {
	open(PIDFILE, "</var/run/syslog-ng.pid");
   } else {
	print "restart_syslogd(): couldn't find pid file\n";
   }

   if (!defined(fileno(PIDFILE)) ) {
	print "FAILED to send SIGHUP to syslogd\n";
	return 0;
   }

   $_ = <PIDFILE>;
   chomp;

   kill(1, ($_));

   1;
}

# simple wrapper to start tcpdumps, assuming obvious globals

sub start_tcpdump {
   my $interface    = shift();
   my $capture_file = shift();
   my $filter       = shift();

   my @cmd = ("$tcpdump", "-s$SNAPLEN", "-ni", "$interface$PREFIX", "-w$capture_file", "$filter");
#   my @cmd = ("$tcpdump", "-s$SNAPLEN","-i$interface$PREFIX", "-w$capture_file", "$filter");

   $DEBUG || open(STDERR, ">/dev/null");
   $DEBUG && print "start_tcpdump(): about to start: ", join(" ", @cmd), "\n";

   exec($cmd[0], @cmd[1..$#cmd]) ||
	print "start_tcpdump(): FAILED to start: ", join(" ", @cmd), ", command not found\n";
   $DEBUG || close(STDERR);

   exit(1);
}

# sub to see how much space a given capture file is using (to decide to rotate or not)

sub capture_space ($) {
   my $capture_file = shift();
   my $size         = ( stat($capture_file) )[7];

   $DEBUG && print "capture_space(): size of $capture_file is $size\n";

   # return size of argument in megabytes, but don't divide by zero
   if ($size == 0) {
	return 0;
   } else {
	return ($size / 1048576);
   }
}

# gives user the option to create a MFS

sub create_mfs () {
   if (-d $CAPTURE_LOCATION) {
	$DEBUG && print "create_mfs(): directory $CAPTURE_LOCATION exists\n";
   } else {
	mkdir($CAPTURE_LOCATION, oct(0755)) || die "FAILED to create $CAPTURE_LOCATION\n";
	print "Capture directory ($CAPTURE_LOCATION) did not exist, so it was created\n";
   }

   # figure out the partition CAPTURE_LOCATION is on.  This is cheap... fixme
   my $partition = $CAPTURE_LOCATION;
   $partition    =~ s!(/[A-z0-9]*)/{0,1}.*!$1!g;

   open(MOUNT, "mount|") || die "FAILED to run \"mount\": !$\n";
   while (<MOUNT>) {
	next unless ((split())[2] =~ /^$partition$/);

	$DEBUG && print "create_mfs(): partition: $partition is already mounted, return\n";

	# return 1 if it's already mounted
	return 1;
   }
   close(MOUNT);

   print "Mount a Memory File System (MFS) on ${CAPTURE_LOCATION}?  [y/n]: ";

   my $answer = <STDIN>;

   if (lc($answer) =~ "y") {
	print "Enter size of MFS in blocks (200000 = 100M), or just press enter for 100M: ";

	chomp (my $mfs_size = <STDIN>);
	$mfs_size = 200000 if ($mfs_size eq "");

	print "Allocating $mfs_size blocks to $CAPTURE_LOCATION for MFS\n";
	system("mount_mfs -s $mfs_size $CAPTURE_LOCATION");

	if (($? >> 8) != 0) {
	   print "an error occurring trying to mount the MFS filesystem, exit status: $?\n";
	   0;
	} else {
	   print "MFS file system established\n\n";
	   1;
	}
   }
}

sub fork_to_background ($) {
   my $cmd = shift();

   my $pid = fork();

   if ($pid == 0) {
        exec($cmd) || die "exec() failed: $!\n";
   } else {
        return($pid);
   }
}

sub popen_read ($) {
   my $cmd   = shift();
   my $child;

   $DEBUG && print "Background: \"$cmd\"\n";

   pipe(READLOG, WRITELOG);
   select(READLOG); $|++; select(WRITELOG); $|++; select(STDOUT);

   ## dup STDOUT and STDERR
   open(T_STDOUT, ">&STDOUT");
   open(T_STDERR, ">&STDERR");

   ## redir STDOUT to pipe for child
   open(STDOUT, ">&WRITELOG");
   open(STDERR, ">&WRITELOG");

   $child = fork_to_background($cmd);

   ## close STDOUT, STDERR and FILE
   close(STDOUT); close(STDERR);

   ## re-open STDOUT as normal and close dup
   open(STDOUT, ">&T_STDOUT"); close(T_STDOUT);
   open(STDERR, ">&T_STDERR"); close(T_STDERR);

   return($child, \*READLOG);
}


sub open_log ($$) {
   my $LOG_FILE = shift();
   my $lines    = shift();

   if (defined($F_LOG) && defined(fileno($F_LOG)) ) {
        $DEBUG && print "Killing child before closing LOG\n";
        kill(15, $tail_child);
        waitpid($tail_child, 0);

        $DEBUG && print "Closing LOG\n";
        close($F_LOG);
   }

   $DEBUG && print "Opening \"$LOG_FILE\"\n";

   ($tail_child, $F_LOG) = popen_read("tail -n $lines -f $LOG_FILE");
   push(@child_pids, $tail_child);

   1;
}

## check to see if log is rotated, returns true if rotated

sub is_rotated ($) {
   my $LOG_FILE = shift();
   
   $DEBUG && print "enter is_rotated()\n";
   
   ($current_inode, $current_size) = (stat($LOG_FILE))[1,7];
   
   if (($last_size != 0) && ($last_size > $current_size)) {
        $DEBUG && print "File is now smaller.  File must have been rotated\n";
        $last_size  = $current_size;
        $last_inode = $current_inode;
       
        open_log($LOG_FILE, $MAX_ROTATED_LINES) || die "open_log $LOG_FILE failed: $!\n";
        return(1);
       
   } elsif (($last_inode != 0) && ($last_inode != $current_inode)) {
        $DEBUG && print "Inode changed.  File must have been rotated\n";
        $last_inode = $current_inode;
        $last_size  = $current_size;
       
        open_log($LOG_FILE, $MAX_ROTATED_LINES) || die "open_log $LOG_FILE failed: $!\n";
        return(1);
       
   }

   ($last_inode, $last_size) = ($current_inode, $current_size);

   0;
}


###########
# MAIN
########

if (free_megabytes() < $min_megabytes) {
   print "free space on $CAPTURE_LOCATION is below ${min_megabytes}MB, you must create a Memory File System or choose another location to gather tcpdumps\n";
   goto MUST_MFS;
}

######### GET USER INPUT ###############

if (free_percent() < $MIN_FREE_SPACE) {
   print "free space on $CAPTURE_LOCATION is below ${MIN_FREE_SPACE}%, you must create a Memory File System or choose another location to gather tcpdumps\n";

MUST_MFS:
   # require the user to create a MFS if they don't have enough free space
   exit(1) unless (create_mfs());
} else {
   create_mfs();
}

if (free_percent() < $MIN_FREE_SPACE || free_megabytes() < $min_megabytes) {
   print "it appears the Memory File System is in place, but there is still insufficient space, exiting\n";
   exit(1);
}

print "capturing to $CAPTURE_LOCATION using the following interfaces and filters:\n";

foreach $interface (keys( %SETTINGS )) {
#   system("ifconfig $interface >/dev/null 2>&1");

#   if ( ($? >> 8) != 0) {
#	$DEBUG && print "couldn't ifconfig $interface, removing from list\n";
#	delete( $SETTINGS{$interface} );
#   } else {
	print "   $interface: $SETTINGS{$interface}{filter}\n";
#   }
}

print "does this look right?  [y/n]: ";

$answer = <STDIN>;
exit unless lc($answer) =~ "y";


####### DAEMONIZE #############
chdir("/");
exit unless (fork() == 0);
    
    
# kill old self, write pid file
if (-f $PID_FILE) {
   open(PIDFILE, "<$PID_FILE");
   kill(15, <PIDFILE>);
   close(PIDFILE);
}

open(PIDFILE, ">$PID_FILE");
syswrite(PIDFILE, $$);
close(PIDFILE);



########### START PROCESSING ###############

foreach $interface (keys( %SETTINGS )) {
   my $filter = $SETTINGS{$interface}{filter};
   $pid       = fork();
   $SETTINGS{$interface}{rotate_number} = 1;

   if (!defined($pid)) {
	print "fork() failed! exiting\n";
	exit 1;
   }

   if ($pid == 0) {
	start_tcpdump(
		$interface,
		"$CAPTURE_LOCATION/${interface}.pcap.$SETTINGS{$interface}{rotate_number}",
		$filter
	);

	exit 1;
   } else {
	$SETTINGS{$interface}{pid} = $pid;
	print "started tcpdump as pid $pid on \"$interface\" filtered as \"$filter\"\n";
   }
}


######
# fork off a process to keep an eye on free space
########

$pid  = fork();

if ($pid == 0) {
   while (1) {
	my $sleep_return = sleep($FREE_SPACE_CHECK_INTERVAL);
	$DEBUG && ($sleep_return != $FREE_SPACE_CHECK_INTERVAL) && print "WARN: free_percent() loop: sleep returned $sleep_return instead of $FREE_SPACE_CHECK_INTERVAL !\n";

	if (free_percent() < $MIN_FREE_SPACE) {
	   print "WARN: free space is below ${MIN_FREE_SPACE}%, killing main script\n";

	   kill(2, $ppid);
	   sleep(1);
	   kill(15, $ppid);

	   print "WARN: sent SIGTERM to $ppid (main script), exiting\n";
	   exit 1;
	} else {
	   $DEBUG && print "free_percent(): space is fine, continue\n";
	}
   }
} else {
   push(@child_pids, $pid);
   $DEBUG && print "started free_percent watcher as: $pid\n";
}


######
# fork off a process to rotate capture files as necessary
########

$pid  = fork();

if ($pid == 0) {
   my $capture_file;

   while (1) {
	my $sleep_return = sleep($CAPTURE_CHECK_INTERVAL);
	$DEBUG && ($sleep_return != $CAPTURE_CHECK_INTERVAL) && print "WARN: start_tcpdump() loop: sleep returned $sleep_return instead of $CAPTURE_CHECK_INTERVAL !\n";

	foreach $interface (keys( %SETTINGS )) {
	   if (capture_space("$CAPTURE_LOCATION/${interface}.pcap.$SETTINGS{$interface}{rotate_number}") >= $DESIRED_CAPTURE_SIZE) {

		if ($SETTINGS{$interface}{rotate_number} == $CAPTURES_TO_ROTATE) {
		   print "reached maximum number of captures to rotate: $CAPTURES_TO_ROTATE, starting over at 1\n";
		   $SETTINGS{$interface}{rotate_number} = 1;
		} else {
		   $SETTINGS{$interface}{rotate_number}++;
		}

		print "rotating capture file: ${interface}.pcap, new extension .$SETTINGS{$interface}{rotate_number}\n";

		$pid = fork();

		if ($pid == 0) {
		   start_tcpdump(
			$interface,
			"$CAPTURE_LOCATION/${interface}.pcap.$SETTINGS{$interface}{rotate_number}",
			$SETTINGS{$interface}{filter},
		   );

		   exit 0;
		}
		push(@child_pids, $pid);

		# get some overlap in the two files
		sleep($OVERLAP_DURING_ROTATE);

		# kill the old tcpdump
		kill(2, $SETTINGS{$interface}{pid});
		$DEBUG && print "sent SIGINT to $interface: $SETTINGS{$interface}{pid}, new pid $pid\n";

		# record the new pid
		$SETTINGS{$interface}{pid} = $pid;
	   } else {
		$DEBUG && print "capture file doesn't need to be rotated yet: ${interface}.pcap\n";
	   }
	}

	# Reap any zombies from old tcpdumps
	$DEBUG && print "start_tcpdump() loop: \@child_pids = (", join(' ', @child_pids), ")\n";
	while (1) {
		use POSIX ":sys_wait_h";
		my $child = waitpid(-1, WNOHANG);
		if (defined $child and $child > 0) {
		    # remove PID from @child_pids
		    @child_pids = grep {$_ != $child} @child_pids;
		    $DEBUG && print "start_tcpdump() loop: reaped child PID $child\n";
		} else {
		    # no one to reap
		    last;
		}
	}
   }
} else {
   push(@child_pids, $pid);
   $DEBUG && print "started capture file watcher as: $pid\n";
}


################
# watch triggers (time or log based)
####################

$SIG{TERM} = sub { finish(); };

if (lc($TRIGGER) =~ /time/) {
   print "time-based trigger, will capture for $TIME_TO_CAPTURE seconds\n";

   sleep($TIME_TO_CAPTURE);

   print "captured for $TIME_TO_CAPTURE seconds, stopping tcpdumps\n";

} elsif (lc($TRIGGER) =~ /log/) {
   print "log-based trigger, waiting for \"$LOG_MESSAGE\" in \"$LOG_FILE\"\n";

   # creates global $F_LOG filehandle of $LOG_FILE
   open_log($LOG_FILE, 0) || finish("open_log $LOG_FILE failed: $!\n");

   # flush syslogd's buffers (avoid never getting the message due to "last message repeated....")
   restart_syslogd() || finish("Restarting syslogd failed, EXIT\n");

   # tail -f the log and wait for message
   while (1) {
	# reap any zombies during each loop
	my $return;

	while (1) {
		use POSIX ":sys_wait_h";
		my $child = waitpid(-1, WNOHANG);
		if (defined $child and $child > 0) {
		    $DEBUG && print "log trigger loop: reaped child PID $child\n";
		} else {
		    # no one to reap
		    last;
		}
	}

	eval {
	   $SIG{ALRM} = sub { die("ALRM\n"); };
           
	   alarm($IDLE_TIMER);
	   $_ = <$F_LOG>;
	   alarm(0);
	};
        
	if ($@) {
	   # this only occurs if we're idle for $IDLE_TIMER seconds because no new log entries are occuring
           
	   $@ = undef;
	   is_rotated($LOG_FILE);
           
	   next;
	}
        
	$DEBUG && print "in LOG reading loop, current line: \"$_\"\n";

	if (/$LOG_MESSAGE/) {
	   $DEBUG && print "Current line matches: \"$LOG_MESSAGE\"\n";

	   last;
	}
        
	$DEBUG && print "no match, next\n";
   }

   print "received log message, sleeping $FOUND_MESSAGE_WAIT seconds then stopping tcpdumps\n";
   sleep($FOUND_MESSAGE_WAIT);
}


# figure out current tcpdump child_pids and push them onto the list

foreach $interface (keys( %SETTINGS )) {
   push(@child_pids, $SETTINGS{$interface}{pid});
}


# kill all tcpdumps + free space watcher + capture file rotator -- doesn't return
finish();

0;
