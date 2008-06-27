#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;
use POSIX;

use Error qw(:try);
use Sys::Hostname;
use Sys::Syslog qw(:standard :macros);
use TheSchwartz;

use Helios;
use Helios::Error;

our $VERSION = '1.90_26';

=head1 NAME

helios.pl - Launch a daemon to service jobs in the Helios job processing system

=head1 SYNOPSIS

 export HELIOS_INI=/path/to/helios.ini
 [export HELIOS_DEBUG=1]
 helios.pl I<jobclass> [--clear-halt]

=head1 DESCRIPTION

The helios.pl program, given a subclass of Helios::Worker, will launch a daemon to service Helios 
jobs of that subclass.  The number of worker processes to run concurrently and various other 
parameters are set via a helios.ini file and the Helios MySQL database (the connection information 
of which is also defined in helios.ini).

Under normal operation, helios.pl will attempt to load the worker class specified on the command 
line and use it to read the contents of the helios.ini file.  If successful, it will attempt to 
connect to the Helios parameter database and read the relevant parameters from there.  If that is 
successful, helios.pl will daemonize and start servicing jobs of the specified class.

In debug mode (set HELIOS_DEBUG=1), helios.pl will not disconnect from the terminal, and will 
output extra debugging information to the screen and the logfile.  It will also enable debug mode 
on the worker class, which may also support outputting debugging information.

If the --clear-halt is specified, helios.pl will attempt to remove a HALT parameter specified in 
the Helios configuration parameters (the helios_params_tb table).  This is helpful if you shutdown 
your Helios service daemon using the Panoptes worker admin view.  Note that it will NOT remove a 
HALT specified globally (where host = '*').

=head1 HELIOS.INI

The initial parameters for helios.pl are defined in an INI-style configuration file typically 
named "helios.ini".  The file's location is normally specified by setting the HELIOS_INI 
environment variable before helios.pl is started.  If HELIOS_INI isn't set, helios.pl will default 
to the helios.ini in the current directory, if present.

A helios.ini file normally contains a [global] section with the parameters necessary to connect 
to the Helios parameter database, and any parameters local to the server the workers run on (e.g. 
log facility and options).  In addition, each worker class can have a section in helios.ini 
containing parameters local only to them.

Example helios.ini:

 [global]
 dsn=dbi:mysql:host=10.1.0.21;db=helios_db
 user=helios
 password=password
 syslog_facility=user
 syslog_options=nofatal,pid

 [ITTB::BroadcastService]
 master_launch_interval=60
 zero_launch_interval=90

 [SearchIndex::LoadTestService]
 OVERDRIVE=1
 MAX_WORKERS=3

=head2 Helios.ini Parameters for helios.pl

=head3 Configuration options to place in the [global] section:

=over 4

=item dsn

Datasource name for the Helios parameter database.  This will also contain the data structures for 
the underlying TheSchwartz queuing system.

=item user

Database user for the datasource name described above.

=item password

Database password for the datasource name described above.

=item syslog_facility

The syslog log facility to send log messages.  The worker class will also log messages to this 
facility.  If a syslog_facility isn't defined, logging to syslog is disabled.  (Uses Sys::Syslog 
CPAN module.)

=item syslog_options

Any desired options for logging to the syslog facility.

=item pid_path

The location where helios.pl should write the PID file for this worker.  The default is 
"/var/run/helios".  The name of the PID file will be a variation on the worker class's name.

=back

=head3 Configuration options to place in individual class sections:

=over 4

=item master_launch_interval

Set the master_launch_interval to determine how long helios.pl should sleep after launching 
jobs before accessing the database to update its configuration parameters and check for waiting 
jobs.  The default is 1 second which works well for normally short-lived jobs (2 secs or less), 
but that may be overkill for longer-lived jobs (jobs that run longer than 2 sec).  Setting the 
master_launch_interval option helps prevent needless database traffic.

=item zero_launch_interval

Set the zero_launch_interval to determine how long helios.pl should sleep after reaching its 
MAX_WORKERS limit.  The default is 2 sec.  If jobs are running long enough that 
helios.pl is frequently hitting is MAX_WORKERS limit (there are waiting jobs but 
helios.pl can't launch new workers because previously launched jobs are still running), increasing 
the zero_launch_interval will reduce needless database traffic.

=back

=head1 HELIOS CTRL PANEL (helios_params_tb)

In addition to helios.ini, certain helios.pl configuration options can be set via the Ctrl Panel 
in the Helios Panoptes web interface.  These configuration options are read by helios.pl from the 
helios_params_tb table in the Helios database.  Though the Ctrl Panel is designed mostly to 
provide a standardized interface for worker classes to store and retrieve configuration 
parameters, certain helios.pl control parameters can be read from here as well.  The helios.pl 
worker daemon will read the parameters via the worker class's getParams() method, so parameters 
can be set for a specific class on a specific host.

The helios.pl daemon will refresh its configuration parameters from the database after waiting 
master_launch_interval seconds after launching worker child processes.  If MAX_WORKERS
workers are still running, the helios.pl daemon will wait zero_launch_interval seconds to refresh
its configuration parameters and try to launch workers again.  If you have long running jobs (jobs 
that last more than a few seconds), resetting these parameters higher may help smooth processing 
and reduce needless database traffic.  See the HELIOS OPERATION section below for more 
information.

=head2 helios.pl Control Parameters in Ctrl Panel

=over 4

=item MAX_WORKERS

The Helios system is designed to run one daemon process for each worker class per server.  However, 
each daemon can run more than 1 worker child process simultaneously.  The upper limit for worker 
processes is set using the MAX_WORKERS option.  The helios.pl default is 1 worker per 
server.  You can provide a different default for a particular class by specifying a value in 
helios.ini.  If active management of available workers is not necessary for a 
particular worker class, this option can be set in helios.ini.

=item OVERDRIVE

Speed up job processing by allowing workers to service jobs until no more are in the queue.  
Normally, a worker process will service a single job and then exit (1:1 worker/job ratio).  With 
OVERDRIVE mode enabled, a worker process will keep servicing jobs until it can find no more of 
that type in the job queue (1:many worker/job ratio).  This may help to speed up processing for 
short-lived jobs, as once worker child processes have started, they stay in memory, continuing to 
process jobs until there are no more to process.  This can also enable on-the-fly caching of 
resources, as once a worker has loaded a resource or established a database connection for a job 
it can be held for use by subsequent jobs, potentially reducing database load or disk I/O.  Longer 
running jobs may not benefit as much, however.

A few extra precautions should be taken in a worker class in order to support OVERDRIVE mode.  If 
the worker class should explicitly exit() if it encounters an error to prevent the error from 
affecting subsequent jobs.  After processing a job successfully (at the end of the work() method)
the process should also exit if the Helios::Worker->shouldExitOverdrive() returns a true value.

Like MAX_WORKERS, if active management of the job processing mode is not necessary, this
parameter can be set in helios.ini (though that is strongly discouraged).

=item HOLD

If set to 1, a HOLD parameter will cause the helios.pl worker daemon to stop launching new workers 
to process jobs.  Currently processing jobs will be allowed to complete, and those worker 
child processes will end normally.  HOLD = 1 will also cause the 
Helios::Worker->shouldExitOverdrive() method to return a true value, which should cause workers 
that correctly support that mode to end after their current job is completed.  

Setting HOLD to 0 will allow normal job processing to resume.

=item HALT

If a HALT parameter is defined, the helios.pl worker daemon will start process cleanup and will 
exit.  As with HOLD = 1, jobs currently processing will complete, and the worker child processes 
will exit normally.  HALT will cause Helios::Worker->shouldExitOverdrive() to return a true value, 
which should cause workers supporting OVERDRIVE mode to exit after they have finished the current 
job.

Once a helios.pl daemon has HALTed, there is no way to restart it from the Helios Pantoptes 
interface.  It must be restarted from the command line with a 'helios.pl <worker::class>' command.

=back

=cut


# globals settings
our $DEBUG_MODE = $ENV{HELIOS_DEBUG};
our $HELIOS_INI = $ENV{HELIOS_INI};
our $CLASS = shift @ARGV;

# other globals
# max workers will default to 1 if not set elsewhere
our %DEFAULTS = (
        MAX_WORKERS => 1,
        HELIOS_INI => './helios.ini',
		PID_PATH => '/var/run/helios',
		MASTER_LAUNCH_INTERVAL => 1,
		ZERO_LAUNCH_INTERVAL => 10,
		ZERO_SLEEP_INTERVAL => 30
);
our $CLEAN_SHUTDOWN = 1;				# used to determine if we should remove the PID file or not (at least for now)

our $HOLD_LOG_INTERVAL = 3600;			# to reduce needless log msg in log_tb while HOLDing
our $HOLD_LOG_LAST = 0;

our $MASTER_LAUNCH_INTERVAL;
our $ZERO_LAUNCH_INTERVAL;

our $START_TIME = time();				# used to measure uptime from the registry table
our $REGISTRATION_INTERVAL = 300;		# used to periodically register daemon in database
our $REGISTRATION_LAST = 0;

our $PID_FILE;							# globally accessible PID file location
our $SAFE_MODE_DELAY = 45;				# SAFE MODE support; number of secs to wait
our $SAFE_MODE_RETRIES = 5;				# SAFE MODE support; number of times to retry 

our $ZERO_SLEEP_INTERVAL;				# to reduce needless checking of the database
our $ZERO_SLEEP_LOG_INTERVAL = 3600;	# to reduce needless log msgs in log_tb
our $ZERO_SLEEP_LOG_LAST = 0;

# print help if asked
if ( !defined($CLASS) || ($CLASS eq '--help') || ($CLASS eq '-h') ) {
	require Pod::Usage;
	Pod::Usage::pod2usage(-verbose => 2, -exitstatus => 0);
}

# conditionally load module or die in the attempt
my $worker_class = $CLASS;
print "Helios ",$Helios::VERSION,"\n";
print "helios.pl Service Daemon version $VERSION\n";
print "Attempting to load $worker_class...\n"; 
unless ( $worker_class->can('new') ) {
        eval "require $worker_class";
        die $@ if $@;
}
print $worker_class, ' ', $worker_class->VERSION," loaded.\n";
if ($DEBUG_MODE) { print "Debug Mode enabled.\n"; }

# instantiate a worker to access the necessary settings
my $worker = new $worker_class;
$worker->setHostname(hostname);
if ( defined($HELIOS_INI) ) {
        $worker->setIniFile( $HELIOS_INI );
} else {
        $worker->setIniFile( $DEFAULTS{HELIOS_INI} );
}
$worker->setJobType($worker_class);
$worker->debug($DEBUG_MODE);
eval {
        $worker->getConfigFromIni();
        $worker->getConfigFromDb();
};
if ($@) {
        die("FAILED to get configuration: $@");
}

my $params = $worker->getConfig();
if ($DEBUG_MODE) {
        print "--INITIAL PARAMS--\n";
        foreach my $param (keys %$params) {
                print $param, ":", $params->{$param},"\n";
        }
}

# SETUP OPERATIONAL PARAMETERS
if ( defined($params->{master_launch_interval}) ) {
	$MASTER_LAUNCH_INTERVAL = $params->{master_launch_interval};
} else {
	$MASTER_LAUNCH_INTERVAL = $DEFAULTS{MASTER_LAUNCH_INTERVAL};
}
if ( defined($params->{zero_launch_interval}) ) {
	$ZERO_LAUNCH_INTERVAL = $params->{zero_launch_interval};
} else {
	$ZERO_LAUNCH_INTERVAL = $DEFAULTS{ZERO_LAUNCH_INTERVAL};
}
if ( defined($params->{zero_sleep_interval}) ) {
	$ZERO_SLEEP_INTERVAL = $params->{zero_sleep_interval};
} else {
	$ZERO_SLEEP_INTERVAL = $DEFAULTS{ZERO_SLEEP_INTERVAL};
}

if ($DEBUG_MODE) { 
	print "MASTER LAUNCH INTERVAL: $MASTER_LAUNCH_INTERVAL\n"; 
	print "ZERO LAUNCH INTERVAL: $ZERO_LAUNCH_INTERVAL\n"; 
}

my %workers;
my $pid;

my $waiting_jobs = 0;
my $running_workers = 0;
my $max_workers = $DEFAULTS{MAX_WORKERS};

our $DATABASES_INFO = [
                {       dsn => $params->{dsn},
                        user => $params->{user},
                        pass => $params->{password}
                }
                ];

my $times_thru_loop = 0;
my $times_waiting = 0;
my $times_sleeping = 0;

# attempt to clear a HALT parameter, if specified
# then we'll check to see if HALT is still there
# if it is, we'll have to stop here rather than 
# daemonize and launch the main loop
if ( defined($ARGV[0]) && lc($ARGV[0]) eq '--clear-halt' ) {
	clear_halt();
	$worker->getConfigFromIni();
	$worker->getConfigFromDb();
	$params = $worker->getConfig();
}
if ( defined($params->{HALT}) ) {
	print STDERR "HALT is set for this service class.\n";
	print STDERR "Please clear it and try again.\n";
	print STDERR $worker_class," HALTED.\n";
	exit(1);
}
# final check before we launch:  
# check to make sure a daemon for this service isn't already running
if ( running_process_check($params->{pid_path}) ) {
	print STDERR $worker->errstr(),"\n";
	exit(1);
}

# Daemonize unless we're in debug mode
unless ($DEBUG_MODE) {
	daemonize();
} else {
	# print debug message
	print "Writing pid file...\n";
	write_pid_file($params->{pid_path}) or die($worker->errstr);
	print "Executing main loop...\n";
}

# set up signal handler to reap dead children
$SIG{CHLD} = \&reaper;

=head1 HELIOS OPERATION

After initial setup, the helios.pl daemon will enter a main operation loop where configuration 
parameters are refreshed, the job queue is checked, and worker child processes are launched and 
cleaned up after.  A HOLD  = 1 parameter will temporarily cause the loop to pause processing, while
a HALT parameter will cause the helios.pl daemon to exit the loop, clean up, and exit.

There are several steps in the helios.pl main operation loop:

=over 4

=item 1.

Refresh configuration parameters from database

=item 2.

Check job queue to see if there are jobs available for processing (if not, sleep for 
zero_sleep_interval seconds and start again).

=item 3.

If there are jobs available, check to see how many worker child processes are currently running.  
If MAX_WORKERS workers are already running, sleep for zero_launch_interval seconds and 
start again.  The zero_launch_interval setting should be long enough to allow at least some of 
the running jobs to complete.

=item 4.

Subtract the number of currently running workers from MAX_WORKERS and launch that many
workers to handle the available jobs.  If MAX_WORKERS is 5 and only 2 workers are 
running, that means the helios.pl daemon will launch 3 workers.

=item 5.

Sleep master_launch_interval seconds and start again.  The master_launch_interval setting should be
long enough to allow at least some of the jobs to complete.

=back

=cut

MAIN_LOOP:{
	try {
	
		# while not halted
		while (!defined($params->{HALT}) ) {
		
				$times_thru_loop++;
		
				# recheck db parameters
				$params = undef;
				$worker->getConfigFromDb();	
				$params = $worker->getConfig();


				# DAEMON REGISTRATION
				# every $REGISTRATION_INTERVAL seconds, (re)register this daemon in the database
				if ( ($REGISTRATION_LAST + $REGISTRATION_INTERVAL) < time() ) {
					register();
					$REGISTRATION_LAST = time();
				}

		
				# HOLDING JOB PROCESSING
				# hold launching jobs temporarily
				if ( defined($params->{HOLD}) && ($params->{HOLD} == 1) ) {
					if ( $HOLD_LOG_LAST + $HOLD_LOG_INTERVAL < time() ) {
						$worker->logMsg("$0 $worker_class HOLDING"); 
						$HOLD_LOG_LAST = time();
					}
					if ($DEBUG_MODE) { print "$0 $worker_class HOLDING\n"; }
					sleep 60; 
					next; 
				}
				# once we're not holding anymore, we'll want to log the next time we enter HOLD mode
				$HOLD_LOG_LAST = 0;
		

				# DETERMINING WORKERS TO LAUNCH
				$waiting_jobs = $worker->jobsWaiting();	
				$running_workers = scalar(keys %workers);
				$max_workers = defined($params->{MAX_WORKERS}) ? $params->{MAX_WORKERS} : $DEFAULTS{MAX_WORKERS};
				if ($DEBUG_MODE) { $worker->logMsg(LOG_DEBUG, "MAX WORKERS: $max_workers"); }
				if ($DEBUG_MODE) { $worker->logMsg(LOG_DEBUG, "RUNNING WORKERS: $running_workers"); }
		
				# if no waiting jobs, sleep
				if ($DEBUG_MODE) { 
					print $waiting_jobs, " waiting ",$worker_class, " jobs.\n"; 
					$worker->logMsg(LOG_DEBUG, $waiting_jobs . " waiting " . $worker_class . " jobs.");
				}
				unless ( $waiting_jobs ) {
						$times_sleeping++;	  #[]
						# only log the "0 workers running, 0 workers in queue.  SLEEPING" message every $ZERO_SLEEP_LOG_INTERVAL seconds
						# (necessary to prevent overwhelming database logging with messages we don't care about)
						if ( ($running_workers == 0) && (($ZERO_SLEEP_LOG_LAST + $ZERO_SLEEP_LOG_INTERVAL ) < time()) ) {
							$worker->logMsg($running_workers." workers running, ".$waiting_jobs." in queue.  SLEEPING");
							$ZERO_SLEEP_LOG_LAST = time();
						}
						sleep $ZERO_SLEEP_INTERVAL;
						next;
				}
				# once we're not zero sleeping ("0 workers running, 0 workers in queue") 
				# we'll want to log the next time we go into zero sleep
				$ZERO_SLEEP_LOG_LAST = 0;
		

				# LAUNCHING WORKERS
				# if we've got to this part of the loop, we have jobs that need workers to launch
				# (though we still may not do it if we've already reached our limit)
				my $workers_to_launch = $max_workers - $running_workers;
				# if the number of waiting jobs is less than max workers
				# then only launch one worker to reduce worker contention
				if ( ($workers_to_launch > 0) && ($waiting_jobs < $max_workers) ) {
					$workers_to_launch = 1;
				}
				$worker->logMsg("$waiting_jobs jobs waiting; $running_workers workers running; launching $workers_to_launch workers");
				for (my $i = 0; $i < $workers_to_launch; $i++) {
		
						FORK: {
							if ($pid = fork) {
										# I'm the parent!
										$workers{$pid} = 1;
										if ($DEBUG_MODE) { $worker->logMsg($worker->getJobType()." process $pid launched");	}
										sleep 1;
								} elsif (defined $pid) { # $pid is zero here if defined
										# I'm the child!
										launch_worker();
							} elsif ($! == EAGAIN) {
								# EAGAIN is the supposedly recoverable fork error
									sleep 2;
								redo FORK;
							} else {
								# weird fork error
									die "Can't fork: $!\n";
							}
						}
		
				}


				# SLEEP INTERVAL AFTER LAUNCHING
				# depending on the worker type, we may need to wait before we go back to the top of the loop
				# (pull new parameters and waiting job count from the database)
				# This can help reduce needless database traffic

				# if there are running jobs but we didn't launch any 
				# (max workers has been reached) sleep for a short while
				# to reduce needless "spinning" (and db access)
				if ( $workers_to_launch <= 0 ) { 
					if ( $DEBUG_MODE ) { $worker->logMsg(LOG_DEBUG, "MAX WORKERS REACHED, SLEEPING"); }
					sleep $ZERO_LAUNCH_INTERVAL; 
					next;
				}

				# if we did launch jobs, depending on the type of worker we may not want to re-check the database yet
				# longer-running jobs (eg Helios::BatchWorker) don't need to have the db checked immediately after launch
				# shorter-running jobs (eg IndexWorker) have likely already completed in the time it took to launch them
				# and we want to launch as many as possible as quickly as possible (esp. if there's a Mass Index operation)
				if ($MASTER_LAUNCH_INTERVAL) {
					if ( $DEBUG_MODE ) { $worker->logMsg(LOG_DEBUG, "MASTER LAUNCH INTERVAL $MASTER_LAUNCH_INTERVAL, SLEEPING"); }
					sleep $MASTER_LAUNCH_INTERVAL;
				}
		}
		
	} otherwise {
		my $e = shift;
		if ($DEBUG_MODE) { 
			print "EXCEPTION THROWN: ",$e->text,"\n"; 
			print "ATTEMPTING TO RECONNECT...\n";
		}
		my $retry;
		my $return_code = 0;
		for($retry = 1; $retry <= $SAFE_MODE_RETRIES; $retry++) {
			my $success = 0;
			try {
				$success = $worker->dbConnect();
			} otherwise {
				# actually, if we fail, we do nothing
			};
			if ($success) {
				$return_code = 1;
				last;
			}
			sleep $SAFE_MODE_DELAY;
		}
		if ($DEBUG_MODE && $return_code) {
			print "DATABASE CONNECTION REESTABLISHED!\n";
		} elsif ($DEBUG_MODE) {
			print "DATABASE RECONNECTION ATTEMPTS FAILED!\n";
		}
		if ($return_code) {
			$worker->logMsg(LOG_CRIT, "Exiting SAFE MODE; Reestablished connection to database after exception: ".$e->text);
			$worker->errstr(undef);
			redo MAIN_LOOP;
		} else {
			$worker->errstr("Unable to reconnect to ".$params->{dsn}.": ".$e->text);
			$CLEAN_SHUTDOWN = 0;
			last MAIN_LOOP;
		}
	};
	
} # end of MAIN_LOOP

# shutdown procedures
if ($CLEAN_SHUTDOWN) {
	# if we're cleanly shutting down (we were told to via helios_params_tb)
	# unregister from Helios database
	# remove our PID
	clean_shutdown();
} else {
	# if we've had a db error, this will throw an exception when it tries to log to the database
	# BUT BEFORE it does that, the error will have been logged to the local syslog daemon
	$worker->logMsg(LOG_CRIT,"$0 $worker_class HALTED on error: ".$worker->errstr);
}

$worker->logMsg("$0 $worker_class HALTED");
if ($DEBUG_MODE) { print "$0 $worker_class HALTED!\n"; }

exit();


=head1 SUBROUTINES

=head2 launch_worker()

The launch_worker() function launches a new TheSchwartz worker of the type specified on the
command line.  After the fork() from the main process, if the process is the child, it calls
launch_worker() to instantiate a new TheSchwartz object, identify the object as one of a certain
job type (TheSchwartz calls it B<ability>), and starts the worker on its way by calling the work()
(or work_until_done(), if OVERDRIVE is enabled) method.

=cut

sub launch_worker {
	my $client = TheSchwartz->new(databases => $DATABASES_INFO);
	$client->can_do($worker_class);
	my $return;
	if ( defined($params->{OVERDRIVE}) && $params->{OVERDRIVE} == 1 ) {
		$return = $client->work_until_done();			
	} else {
		$return = $client->work_once();
	}
	exit($return);
}


=head2 reaper()

The reaper() function is responsible for cleaning up after dead child processes.  It's called when 
helios.pl receives a SIG_CHLD signal.  The function reaps any children with waitpid(), removes the 
child's PID from the $workers hash of running workers, and re-establishes itself as the signal 
handler for the next SIG_CHLD signal.

Don't fear the reaper.

=cut

sub reaper {
	my $pid;
	print "REAPING!\n";
	while (($pid = waitpid(-1, &WNOHANG)) > 0) {
		if ($pid == -1) {
			print "REAPED IGNORING\n";
			# no child waiting.  Ignore it.
		} elsif (WIFEXITED($?)) {
			delete $workers{$pid};
			print "REAPED Process $pid exited.\n";
			print "REAPED $pid: $?\n";
		} else {
			print "REAPED False alarm on $pid.\n"
		}
	}
	print "FINISHED REAPING\n";
	$SIG{CHLD} = \&reaper;
	print "EXIT REAPER!\n";
}


=head2 daemonize() 

The daemonize() function is called to turn the Helios program into a daemon servicing jobs of a 
particular class.  It forks a new process, which disconnects from the launching terminal.

Normally, daemonization also including setting up signal handling, but daemonize() isn't called 
in debug mode, so signal traps are actually set up in the main program.

=cut

sub daemonize {
	my $pid = fork;   
	# make sure fork was successful
	unless ( defined($pid) ) {
		die "Cannot daemonize: $!";
	}

	# we forked, but are we parent or child?
	if ($pid) {
		# we got a PID, so we're the parent ("shell-called process")
		# print a nice message about daemonizing and exit
		print "$worker_class daemon launched.\n";
		exit();
	} 

	# we got 0, so we're the "child", or the parent daemon
	# we need to write our PID out to a file 
	# and then disconnect completely from the shell
	write_pid_file($params->{pid_path}) or die($worker->errstr);

	# Detach from the shell entirely by setting our own
	# session and making our own process group
	# as well as closing any standard open filehandles.
	POSIX::setsid();
	close (STDIN); 
	close (STDOUT); 
	close (STDERR);

	# set up signal handling in main process 
}


=head2 write_pid_file($pid_path)

Writes a PID file to a location (defaults to /var/run/helios) to track which daemons are 
running.  The file will be named after the worker class running, all lowercase, with colons 
replaced by underscores.  For example, the PID file for a worker class named 
'SearchIndex::LoadTestWorker' will be named "searchindex__loadtestworker.pid".  To change the 
location where the PID file is created, set the pid_path option in helios.ini.

=cut

sub write_pid_file {
	my $pid_path = shift;
	my $fh;
	# Determine where to put the PID file
	unless (defined($pid_path) ) {
		$pid_path = $DEFAULTS{PID_PATH};
	}

	# Determine PID filename
	my $filename = lc($worker_class);
	$filename =~ s/\:/\_/g;
	$PID_FILE = $pid_path . '/' . $filename . '.pid';
	if ($DEBUG_MODE) { print "Writing pid file $PID_FILE\n";	}
	
	open $fh, ">", $PID_FILE or do { $worker->errstr("Cannot write PID file $PID_FILE: ".$!); return undef; };
	print $fh $$;
	close $fh;

	return 1;
}


=head2 remove_pid_file($pid_file)

During a clean shutdown, the PID file should be removed.  If the daemon encountered an 
unrecoverable error, this function shouldn't be called, and a cron job on the server 
should notice the process has disappeared and restart it.

=cut

sub remove_pid_file {
	my $pid_file = shift;
	unless ( defined($pid_file) ) {
		$pid_file = $PID_FILE;
	}
	unlink $pid_file or do { $worker->errstr("Cannot remove PID file $pid_file: ".$!); return undef; };
	return 1;
}


=head2 running_process_check($pid_path)

Given the pid_path, check to see if a $pid_file for the loaded service class exists and, if it does,
check to see if that process is still running.  If the file doesn't exist or it does but isn't 
running, this function returns 0.  If the process is still running, record the error and return the 
running process's pid to signal that service startup should halt. 

=cut

sub running_process_check {
	my $pid_path = shift;
	# Determine where the PID file should be
	unless (defined($pid_path) ) { $pid_path = $DEFAULTS{PID_PATH}; }

	# Determine PID filename
	my $filename = lc($worker_class);
	$filename =~ s/\:/\_/g;
	$PID_FILE = $pid_path . '/' . $filename . '.pid';
	if ($DEBUG_MODE) { print "Checking $PID_FILE\n"; }

	# check if this file exists
	# if it does, check if that process is still running
	# bail if it is
	if (-r $PID_FILE) {
		my $pid = `cat $PID_FILE`;
		my $pinfo = `ps -p $pid|wc -l`;
		# is this process still running?
		if ($pinfo > 1) {
			$worker->errstr($worker->getJobType()." service daemon already running (process ".$pid.").");
			return $pid;
		} 
	}
	return 0;
}


=head2 clear_halt()

If the --clear-halt option is specified on the command line, clear_halt() is called to attempt to 
clear the HALT parameter in the helios_params_tb.  For safety reasons, it only clears a HALT for 
the loaded service class AND the specific host helios.pl is running on; it will not clear a global
HALT parameter (where the host is specified as '*').

=cut

sub clear_halt {
	try {
		if ($DEBUG_MODE) { 
			print "Attempting to delete HALT for ",$worker->getJobType()," on ",$worker->getHostname(),"\n"; 
		}
		my $dbh = $worker->dbConnect();
		$dbh->do("DELETE FROM helios_params_tb WHERE worker_class = ? AND host = ? AND param = ?", undef, 
					$worker->getJobType(), $worker->getHostname, 'HALT');
	} otherwise {
		throw Helios::Error::DatabaseError($DBI::errstr);
	};
	return 1;	
}


=head2 clean_shutdown()

The clean_shutdown function is called when helios.pl is intentionally shutdown (setting a 
parameter of HALT with a value of 1 in helios_params_tb).  It removes the PID file created on 
startup and unregisters the worker daemon from the database.

=cut 

sub clean_shutdown {
	remove_pid_file() or $worker->logMsg(LOG_CRIT, $worker->errstr);
	unregister() or $worker->logMsg(LOG_CRIT, $worker->errstr);
	return 1;
}


=head2 register()

The register() function records information about the currently running worker daemon in the 
database.  The register() function is designed to be run every $REGISTRATION_INTERVAL seconds.  
That way, if a worker daemon dies off unexpectedly (without calling unregister()), it can be 
determined that something has happened to the daemon and it possibly needs to be restarted.

(In reality, register() and unregister() are only necessary to provide a display for Panoptes, 
to more easily assess system status and facilitate the HALTing of worker daemons or HOLDing of 
jobs.)

=cut

sub register {
	try {
		my $dbh = $worker->dbConnect();
		$dbh->do("DELETE FROM helios_worker_registry_tb WHERE worker_class = ? AND host = ?", undef, 
					$worker->getJobType(), $worker->getHostname) or die;
		$dbh->do("INSERT INTO helios_worker_registry_tb (register_time, start_time, worker_class, worker_version, host, process_id) VALUES (?,?,?,?,?,?)", undef,
					time(), $START_TIME, $worker->getJobType(), $worker->VERSION, $worker->getHostname, $$) or die;
	} otherwise {
		throw Helios::Error::DatabaseError($DBI::errstr);
	};
	return 1;
}


=head2 unregister()

The unregister() function removes any record of the currently running daemon from the database.  
It should be called whenever there is a clean shutdown.

=cut

sub unregister {
	try {
		my $dbh = $worker->dbConnect();
		$dbh->do("DELETE FROM helios_worker_registry_tb WHERE worker_class = ? AND host = ?", undef, 
					$worker->getJobType(), $worker->getHostname) or die;
		$dbh->disconnect();
	} otherwise {
		throw Helios::Error::DatabaseError($DBI::errstr);
	};
	return 1;
}


=head1 SEE ALSO

L<Helios>, L<Helios::Service>

=head1 AUTHOR

Andrew Johnson, E<lt>ajohnson@ittoolbox.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2007-8 by CEB Toolbox, Inc.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.0 or,
at your option, any later version of Perl 5 you may have available.

=head1 WARRANTY

This software comes with no warranty of any kind.

=cut

