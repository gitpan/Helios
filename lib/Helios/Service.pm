package Helios::Service;

use 5.008;
use base qw( TheSchwartz::Worker );
use strict;
use warnings;
use File::Spec;
use Sys::Hostname;
use Config::IniFiles;
use DBI;
use Data::ObjectDriver::Driver::DBI;
use Error qw(:try);
use TheSchwartz;
use TheSchwartz::Job;
require XML::Simple;
$XML::Simple::PREFERRED_PARSER = 'XML::Parser';

use Helios::Error;
use Helios::Job;
use Helios::ConfigParam;
use Helios::LogEntry;
use Helios::LogEntry::Levels qw(:all);

our $VERSION = '2.22';

our $CACHED_CONFIG;
our $CACHED_CONFIG_RETRIEVAL_COUNT = 0;
our $WORKER_START_TIME = 0;

=head1 NAME

Helios::Service - base class for services in the Helios job processing system

=head1 DESCRIPTION

Helios::Service is the base class for all services intended to be run by the 
Helios parallel job processing system.  It handles the underlying TheSchwartz job queue system and 
provides additional methods to handle configuration, job argument parsing, logging, and other 
functions.

A Helios::Service subclass must implement only one method:  the run() method.  The run() method 
will be passed a Helios::Job object representing the job to performed.  The run() method should 
mark the job as completed successfully, failed, or permanently failed (by calling completedJob(),
failedJob(), or failedJobPermanent(), respectively) before it ends.  

=head1 TheSchwartz HANDLING METHODS

The following 3 methods are used by the underlying TheSchwartz job queuing 
system to determine what work is to be performed and, a job fails, how it 
should be retried.

YOU DO NOT NEED TO TOUCH THESE METHODS TO CREATE HELIOS SERVICES.  These 
methods manage interaction between Helios and TheSchwartz.  You only need to 
be concerned with these methods if you are attempting to extend core Helios
functionality.  

=head2 max_retries()

Controls how many times a job will be retried.  

=head2 retry_delay()

Controls how long (in secs) before a failed job will be retried.  

These two methods should return the number of times a job can be retried if it fails and the 
minimum interval between those retries, respectively.  If you don't define them in your subclass, 
they default to zero, and your job(s) will not be retried if they fail.

=head2 work()

The work() method is the method called by the underlying TheSchwartz::Worker (which in turn is 
called by the helios.pl service daemon) to perform the work of a job.  Effectively, work() sets 
up the worker process for the Helios job, and then calls the service subclass's run() method to 
run it.

The work() method is passed a job object from the underlying TheSchwartz job queue system.  The 
service class is instantiated, and the the job is recast into a Helios::Job object.  The service's 
configuration parameters are read from the system and made available as a hashref via the 
getConfig() method.  The job's arguments are parsed from XML into a Perl hashref, and made 
available via the job object's getArgs() method.  Then the service object's run() method is 
called, and is passed the Helios::Job object.

Once the run() method has completed the job and returned, work() determines whether the worker 
process should exit or stay running.  If the subclass run() method returns a zero and the worker is 
OVERDRIVE mode, the worker process will stay running, and work() will be called to setup and run 
another job.  If the run() method returned a nonzero value or the shouldExitOverdrive() returns a 
true value, the worker process will exit.  If OVERDRIVE mode is disabled, the process will also exit.

=cut

sub max_retries { return MaxRetries(); }
sub retry_delay { return RetryInterval(); }

sub work {
	my $class = shift;
	my $schwartz_job = shift;
	my $job = $class->JobClass() ? $class->JobClass()->new($schwartz_job) : Helios::Job->new($schwartz_job);
	$WORKER_START_TIME = $WORKER_START_TIME ? $WORKER_START_TIME : time();     # for WORKER_MAX_TTL 
	my $return_code;
	my $args;

	# instantiate the service class into a worker
	my $self = new $class;
	try {
	    # if we've previously retrieved a config
        # AND OVERDRIVE is enabled (1) 
        # AND LAZY_CONFIG_UPDATE is enabled (1),
        # AND we're not servicing the 10th job (or technically a multiple of ten)
        # THEN just retrieve the pre-existing config
        
        #[]
        print "CACHED_CONFIG=",$CACHED_CONFIG,"\n";
        print "CACHED_CONFIG_RETRIEVAL_COUNT=",$CACHED_CONFIG_RETRIEVAL_COUNT,"\n";
        
        if ( defined($CACHED_CONFIG) && 
                $CACHED_CONFIG->{LAZY_CONFIG_UPDATE} == 1 &&
                $CACHED_CONFIG->{OVERDRIVE} == 1 &&
                $CACHED_CONFIG_RETRIEVAL_COUNT % 10 != 0 
            ) {
            $self->prep($CACHED_CONFIG);
            $CACHED_CONFIG_RETRIEVAL_COUNT++;
            if ($self->debug) { $self->logMsg(LOG_DEBUG,"Retrieved config params from in-memory cache"); }    #[] take this out before release
        } else {
            $self->prep();
            if ( defined($self->getConfig()->{LAZY_CONFIG_UPDATE}) && 
                    $self->getConfig()->{LAZY_CONFIG_UPDATE} == 1 ) {
                $CACHED_CONFIG = $self->getConfig();
                $CACHED_CONFIG_RETRIEVAL_COUNT = 1;     # "prime the pump"
            }	    
        }
	    	    
		$job->setConfig($self->getConfig());
		$job->debug( $self->debug );
		$args = $job->parseArgs();
	} catch Helios::Error::InvalidArg with {
		my $e = shift;
		$self->logMsg($job, LOG_ERR, "Invalid arguments: ".$e->text);
		$job->failedNoRetry($e->text);			
		exit(1);
	} catch Helios::Error::DatabaseError with {
		my $e = shift;
		$self->logMsg($job, LOG_ERR, "Database error: ".$e->text);
		$job->failed($e->text);
		exit(1);
	} otherwise {
		my $e = shift;
		$self->logMsg($job, LOG_ERR, "Unexpected error: ".$e->text);
		$job->failed($e->text);
		exit(1);
	};

	# if this is a meta job, we need to burst it apart 
	# if it isn't, we should call the service's run() method 
	$self->setJob($job);
	if ( defined($args->{metajob}) && $args->{metajob} == 1 ) {
		$self->logMsg($job, LOG_NOTICE, 'Job '.$job->getJobid.' is a metajob.  Bursting...');
		try {
			my $numberOfJobs = $self->burstJob($job);
			$self->logMsg($job, LOG_NOTICE, 'Job '.$job->getJobid.' burst into '.$numberOfJobs.' jobs');
		} otherwise {
			my $e = shift;
			$self->logMsg($job, LOG_ERR, 'Job '.$job->getJobid.' burst failure: '.$e->text);
		};
	} else {
		if ($self->debug) { print "RUNNING JOB\n"; }
		$return_code = $self->run($job);
		if ($self->debug) { print "RUN RETURN CODE: ", $return_code,"\n"; }
	}

	# either run() or burstJob() should have marked the job as completed or failed
	# now we have to decide whether to exit or not

	# if run() returned a nonzero, we're assuming run() ended badly, 
	# and we need to exit the process to be safe
	if ($return_code != 0) { exit(1); }

	# if we're not in OVERDRIVE, the worker process will exit as soon as work() returns anyway 
	#    (calling shouldExitOverdrive will be a noop)
	# if we're in OVERDRIVE, work() will exit and the worker process will call it again with another job
	# if we were in OVERDRIVE, but now we're NOT, we should explicitly exit() to accomplish the downshift
	if ( $self->shouldExitOverdrive() ) {
		$self->logMsg(LOG_NOTICE,"Class $class exited (downshift)");
		exit(0);
	}
}


=head1 ACCESSOR METHODS

These accessors will be needed by subclasses of Helios::Service.

 get/setConfig()
 get/setHostname()
 get/setIniFile()
 get/setJob()
 get/setJobType()
 errstr()
 debug()

Most of these are handled behind the scenes simply by calling the prep() method.

After calling prep(), calling getConfig() will return a hashref of all the configuration parameters
relevant to this service class on this host.

If debug mode is enabled (the HELIOS_DEBUG env var is set to 1), debug() will return a true value, 
otherwise, it will be false.  Some of the Helios::Service methods will honor this value and log 
extra debugging messages either to the console or the Helios log (helios_log_tb table).  You can 
also use it within your own service classes to enable/disable debugging messages or behaviors.

=cut

sub setJob { $_[0]->{job} = $_[1]; }
sub getJob { return $_[0]->{job}; }

# need for helios.pl logging	
sub setJobType { $_[0]->{jobType} = $_[1]; }
sub getJobType { return $_[0]->{jobType}; }

sub setConfig { $_[0]->{config} = $_[1]; }
sub getConfig { return $_[0]->{config}; }

sub setFuncid { $_[0]->{funcid} = $_[1]; }
sub getFuncid { return $_[0]->{funcid}; }

sub setIniFile { $_[0]->{inifile} = $_[1]; }
sub getIniFile { return $_[0]->{inifile}; }

sub setHostname { $_[0]->{hostname} = $_[1]; }
sub getHostname { return $_[0]->{hostname}; }

sub errstr { my $self = shift; @_ ? $self->{errstr} = shift : $self->{errstr}; }
sub debug { my $self = shift; @_ ? $self->{debug} = shift : $self->{debug}; }


=head1 CONSTRUCTOR

=head2 new()

The new() method doesn't really do much except create an object of the appropriate class.  (It can 
overridden, of course.)

It does set the job type for the object (available via the getJobType() method).

=cut

sub new {
	my $caller = shift;
	my $class = ref($caller) || $caller;
#	my $self = $class->SUPER::new(@_);
	my $self = {};
	bless $self, $class;

	# init fields
	my $jobtype = $caller;
	$self->setJobType($jobtype);

	return $self;
}


=head1 INTERNAL SERVICE CLASS METHODS

When writing normal Helios services, the methods listed in this section will 
have already been dealt with before your run() method is called.  If you are 
extending Helios itself or instantiating a Helios service outside of Helios 
(for example, to retrieve a service's config params), you may be interested in 
some of these, primarily the prep() method. 

=head2 prep()

The prep() method is designed to call all the various setup routines needed to 
get the service ready to do useful work.  It:

=over 4

=item * 

Pulls in the contents of the HELIOS_DEBUG and HELIOS_INI env vars, and sets the appropriate 
instance variables if necessary.

=item *

Calls the getConfigFromIni() method to read the appropriate configuration parameters from the 
INI file.

=item *

Calls the getConfigFromDb() method to read the appropriate configuration parameters from the 
Helios database.

=back

Normally it returns a true value if successful, but if one of the getConfigFrom*() methods throws 
an exception, that exception will be raised to your calling routine.

=cut

sub prep {
	my $self = shift;
	my $cached_config = shift;

	# pull params from environment
	$self->setHostname(hostname);
	if ( defined($ENV{HELIOS_DEBUG}) ) {
		$self->debug($ENV{HELIOS_DEBUG});
	}
	if ( defined($ENV{HELIOS_INI}) && 
		!defined($self->getIniFile) ) {
		$self->setIniFile($ENV{HELIOS_INI});
	}

    if ( defined($cached_config) ) {
        $self->setConfig($cached_config);
        return 1;        
    }

	# now get the Helios conf params from INI and db
	# (these may throw their own errors that the calling routine
	#  will have to catch)
	$self->getConfigFromIni();
	$self->getConfigFromDb();

	return 1;
}


=head2 getConfigFromIni([$inifile])

The getConfigFromIni() method opens the helios.ini file, grabs global params and config params relevant to
the current service class, and returns them in a hash to the calling routine.  It also sets the class's 
internal {config} hashref, so the config parameters are available via the getConfig() method.

Typically service classes will call this once near the start of processing to pick up any relevant 
parameters from the helios.ini file.  However, calling the prep() method takes care of this for 
you, and is the preferred method.

=cut

sub getConfigFromIni {
	my $self = shift;
	my $inifile = shift;
	my $jobtype = $self->getJobType();
	my %params;

	# use the object's INI file if we weren't given one explicitly
	# or use the contents of the HELIOS_INI env var
	unless ($inifile) {
		if ( $self->getIniFile() ) {
			$inifile = $self->getIniFile();
		} elsif ( defined($ENV{HELIOS_INI}) ) {
			$inifile = $ENV{HELIOS_INI};
		} elsif (-r File::Spec->catfile(File::Spec->curdir,'helios.ini') ) {
			$inifile = File::Spec->catfile(File::Spec->curdir,'helios.ini');
		} else {
			throw Helios::Error::InvalidArg("INI configuration file not specified.");
		}
	}

	if ( $self->debug() ) { print "inifile: $inifile\nclass:$jobtype\n"; }		
	unless (-r $inifile) { $self->errstr("INI read error: $!"); return undef; }

	my $ini = new Config::IniFiles( -file => $inifile );
	unless ( defined($ini) ) { throw Helios::Error::Fatal("Invalid INI file; check configuration"); }

	# global must exist; it's where the helios db is declared
	if ($ini->SectionExists("global") ) {
		foreach ( $ini->Parameters("global") ) {
			$params{$_} = $ini->val("global", $_);
		}
	} else {
		throw Helios::Error::InvalidArg("Section [global] doesn't exist in config file $inifile");
	}
	
	# if there's a section specifically for this service class, read it too
	# (it will effectively override the global section, BTW)
	if ( $ini->SectionExists($jobtype) ) {
		foreach ( $ini->Parameters($jobtype) ) {
			$params{$_} = $ini->val($jobtype, $_);
		}
	}

	$self->setConfig(\%params);
	return %params;
}


=head2 getConfigFromDb()

The getConfigFromDb() method connects to the Helios database, retrieves config params relevant to the 
current service class, and returns them in a hash to the calling routine.  It also sets the class's 
internal {config} hashref, so the config parameters are available via the getConfig() method.

Typically service classes will call this once near the start of processing to pick up any relevant 
parameters from the helios.ini file.  However, calling the prep() method takes care of this for 
you.

There's an important subtle difference between getConfigFromIni() and getConfigFromDb():  
getConfigFromIni() erases any previously set parameters from the class's internal {config} hash, 
while getConfigFromDb() merely updates it.  This is due to the way helios.pl uses the methods:  
the INI file is only read once, while the database is repeatedly checked for configuration 
updates.  For individual service classes, the best thing to do is just call the prep() method; it 
will take care of things for the most part.

=cut

sub getConfigFromDb {
	my $self = shift;
	my $params = $self->getConfig();
	my $hostname = $self->getHostname();
	my $jobtype = $self->getJobType();
	my @cps;
	my $cp;

	if ($self->debug) { print "Retrieving params for ".$self->getJobType()." on ".$self->getHostname()."\n"; }

	try {
		my $driver = $self->getDriver();
		@cps = $driver->search('Helios::ConfigParam' => {
				worker_class => $jobtype,
				host         => '*',
			}
		);
		foreach $cp (@cps) {
			if ($self->debug) { 
				print $cp->param(),'=',$cp->value(),"\n";
			}
			$params->{$cp->param()} = $cp->value();
		}
		@cps = $driver->search('Helios::ConfigParam' => {
				worker_class => $jobtype,
				host         => $hostname,
			}
		);
		foreach $cp (@cps) {
			if ($self->debug) { 
				print $cp->param(),'=',$cp->value(),"\n";
			}
			$params->{$cp->param()} = $cp->value();
		}
		
	} otherwise {
		my $e = shift;
		throw Helios::Error::DatabaseError($e->text);
	};

	$self->setConfig($params);
	return %{$params};
}


=head2 getFuncidFromDb()

=cut

sub getFuncidFromDb {
    my $self = shift;
    my $params = $self->getConfig();
    my $jobtype = $self->getJobType();
    my @funcids;

    if ($self->debug) { print "Retrieving funcid for ".$self->getJobType()."\n"; }

    try {
        my $driver = $self->getDriver();
        # also get the funcid 
        my @funcids = $driver->search('TheSchwartz::FuncMap' => {
                funcname => $jobtype 
            }
        );
        if ( scalar(@funcids) > 0 ) {
            $self->setFuncid( $funcids[0]->funcid() );
        }
		
	} otherwise {
		my $e = shift;
		throw Helios::Error::DatabaseError($e->text);
	};
    return $self->getFuncid();	
}


=head2 jobsWaiting() 

Scans the job queue for jobs that are ready to run.  Returns the number of jobs 
waiting.  Only meant for use with the helios.pl service daemon.

=cut

sub jobsWaiting {
	my $self = shift;
	my $params = $self->getConfig();
	my $jobType = $self->getJobType();
	my $funcid;

	try {

		my $dbh = $self->dbConnect($params->{dsn}, $params->{user}, $params->{password});
		unless ($dbh) { throw Helios::Error::DatabaseError($self->errstr); }

		# get the funcid if we don't already have it
		if ( !defined($self->getFuncid()) ) {
		    $funcid = $self->getFuncidFromDb();
		} else {
		    $funcid = $self->getFuncid();
		}

		my $sql2 = <<JWSQL2;
SELECT COUNT(*)
FROM job
WHERE funcid = ?
	AND (run_after < ?)
	AND (grabbed_until < ?)
JWSQL2
		my $sth2 = $dbh->prepare($sql2);

		my $current_time = time();
		$sth2->execute($funcid, $current_time, $current_time);
		my $result2 = $sth2->fetchrow_arrayref();
		unless ( defined($result2->[0]) ) {
			$self->errstr("Received NULL value in jobsWaiting() for funcname $jobType!"); return undef; 
		}
		$sth2->finish();
		$dbh->disconnect();
		return $result2->[0];

	} otherwise {
		throw Helios::Error::DatabaseError($DBI::errstr);
	};
	
}


=head2 getDriver()

Returns a Data::ObjectDriver object for use with the Helios database.

=cut

sub getDriver {
	my $self = shift;
	my $config = $self->getConfig();
	my $driver = Data::ObjectDriver::Driver::DBI->new(
	    dsn      => $config->{dsn},
	    username => $config->{user},
	    password => $config->{password}
	);	
	return $driver;	
}


=head2 shouldExitOverdrive()

Determine whether or not to exit if OVERDRIVE mode is enabled.  The config 
params will be checked for HOLD, HALT, or OVERDRIVE values.  If HALT is defined 
or HOLD == 1 this method will return a true value, indicating the worker 
process should exit().

This method is used by helios.pl and Helios::Service->work().  Normal Helios
services do not need to use this method directly.

=cut

sub shouldExitOverdrive {
	my $self = shift;
	my $params = $self->getConfig();
	if ( defined($params->{HALT}) ) { return 1; }
	if ( defined($params->{HOLD}) && $params->{HOLD} == 1) { return 1; }
	if ( defined($params->{WORKER_MAX_TTL}) && $params->{WORKER_MAX_TTL} > 0 && 
	       time() > $WORKER_START_TIME + $params->{WORKER_MAX_TTL} ) {
        return 1;
    }
	return 0;
}


=head1 METHODS AVAILABLE TO SERVICE SUBCLASSES

The methods in this section are available for use by Helios services.  They 
allow your service to interact with the Helios environment.

=head2 dbConnect($dsn, $user, $password)

Method to connect to a database.  If parameters not specified, uses dsn, user, password 
from %params hash (the Helios database).

This method uses the DBI->connect_cached() method to attempt to reduce the number of open 
connections to a particular database.

=cut

sub dbConnect {
	my $self = shift;
	my $dsn = shift;
	my $user = shift;
	my $password = shift;
	my $options = shift;
	my $params = $self->getConfig();

	# if we weren't given params
	unless ($dsn) {
		$dsn = $params->{dsn};
		$user = $params->{user};
		$password = $params->{password};
		$options = $params->{options};
	}

	try {

		my $dbh;
		if ($options) {
			my $o = eval "{$options}";
			if ($@) { $self->errstr($@); return undef;	}
			if ($self->debug) { print "dsn=$dsn\nuser=$user\npass=$password\noptions=$options\n"; }	
			$dbh = DBI->connect_cached($dsn, $user, $password, $o);	
		} else {
			if ($self->debug) { print "dsn=$dsn\nuser=$user\npass=$password\n";	} 
			$dbh = DBI->connect_cached($dsn, $user, $password);
		}
#[]		if ( $DBI::errstr ) { 
        unless ( defined($dbh) ) {
			$self->errstr("DB ERROR: ".$DBI::errstr); 
			throw Helios::Error::DatabaseError($DBI::errstr);
		}
		$dbh->{RaiseError} = 1;
		return $dbh;

	} otherwise {
		throw Helios::Error::DatabaseError($DBI::errstr);
	};

}


=head2 logMsg([$job,] [$priority,] $msg)

Record a message in the Helios log.  In addition to the log message, there are 
two optional parameters:

=over 4

=item $job

The current Helios::Job object being processed.  If specified, the jobid will 
be logged in the database along with the message.

=item $priority

The priority level of the message as defined by Helios::LogEntry::Levels.  
These are really integers, but if you import Helios::LogEntry::Levels (with the 
:all tag) into your namespace, your logMsg() calls will be much more readable.  
There are 8 log priority levels, corresponding (for historical reasons) to 
the log priorities defined by Sys::Syslog:

    name         priority
    LOG_EMERG    0
    LOG_ALERT    1
    LOG_CRIT     2
    LOG_ERR      3
    LOG_WARNING  4
    LOG_NOTICE   5
    LOG_INFO     6
    LOG_DEBUG    7
   
LOG_DEBUG, LOG_INFO, LOG_NOTICE, LOG_WARNING, and LOG_ERR are the most common 
used by Helios; LOG_INFO is the default.

=back

As of Helios 2.2, you can specify a logging threshold to better control the 
logging of your service on-the-fly.  Specifying a 'log_priority_threshold' 
config parameter in your helios.ini or Ctrl Panel will cause log messages of a 
lower priority (higher numeric value) will be discarded.  For example, a line 
in your helios.ini like:

 log_priority_threshold=6   

will cause any log messages of priority 7 (LOG_DEBUG) to be discarded.

The host, process id, and service class are automatically recorded with your log 
message.  If you supplied either a Helios::Job object or a priority level, these
will also be recorded with your log message.

NOTE: Previous Helios versions also had the ability to log messages to syslogd. 
This functionality has been removed; see L<HeliosX::ExtLoggerService> and 
L<HeliosX::Logger::Syslog> if you require this functionality.

=cut

sub logMsg {
	my $self = shift;
	my $priority;
	my $msg;
	my $job;

	# if the first parameter is a Helios::Job object, log extra info
	if ( ref($_[0]) && $_[0]->isa('Helios::Job') ) {
		$job = shift;
	}

	# if we were given 2 params, the first is priority, second message
	# if only one, it is the message, default to LOG_INFO priority
	if ( defined($_[0]) && defined($_[1]) ) {
		$priority = shift;
		$msg = shift;
	} else {
		$priority = LOG_INFO;
		$msg = shift;
	}
	
	my $params = $self->getConfig();
	my $jobType = $self->getJobType();
	my $hostname = $self->getHostname();

    # if this log message's priority is lower than log_priority_threshold,
    # don't bother logging the message
    if ( defined($params->{log_priority_threshold}) &&
        $priority > $params->{log_priority_threshold} ) {
        return 1;
    }

    # Sys::Syslog support
	# log the message to syslog IF log_facility was set
	#[]? removed in favor of HeliosX::Logger::Syslog
=disable
	if ( defined($params->{syslog_facility}) ) {
        unless ( 'Sys::Syslog'->can('openlog') ) {
            eval "require Sys::Syslog";
            throw Helios::Error::Fatal("Unable to load Sys::Syslog: ".$@) if $@;
        }		
		openlog($jobType, $params->{syslog_options}, $params->{syslog_facility});
		syslog($priority, $msg);
		closelog();
	}
=cut

	# log to database
	my $retries = 0;
	my $retry_limit = 3;
	RETRY: {
		try{
			my $driver = $self->getDriver();
			my $log_entry;
			if ( defined($job) ) {
				$log_entry = Helios::LogEntry->new(
					log_time   => time(),
					host       => $self->getHostname,
					process_id => $$,
					jobid      => $job->getJobid,
					funcid     => $job->getFuncid,
					job_class  => $jobType,
					priority   => $priority,
					message    => $msg
				);
			} else {
				$log_entry = Helios::LogEntry->new(
					log_time   => time(),
					host       => $self->getHostname,
					process_id => $$,
					jobid      => undef,
					funcid     => undef,
					job_class  => $jobType,
					priority   => $priority,
					message    => $msg
				);
			}
			$driver->insert($log_entry);		

		} otherwise {
			my $e = shift;
			if ($retries > $retry_limit) {
				throw Helios::Error::DatabaseError($e->text());
			} else {
				# we're going to give it another shot
				$retries++;
				sleep 10;
				next RETRY;
			}
		};
	} # retry block end
	return 1;
}


=head2 parseArgXML($xml) [DEPRECATED]

Given a string of XML, parse it into a mixed hash/arrayref structure.  This uses
XML::Simple.

This method is DEPRECATED; its functionality has been moved to 
Helios::Job->parseArgXML().  You should use the Helios::Service->getJobArgs() 
instead of this method.

=cut

sub parseArgXML {
	my $self = shift;
	my $xml = shift;

	my $xs = XML::Simple->new(SuppressEmpty => undef);
	my $args;
	try {
		$args = $xs->XMLin($xml);
	} otherwise {
		throw Helios::Error::InvalidArg($!);
	};
	return $args;
}


=head2 getJobArgs($job)

Given a Helios::Job object, getJobArgs() returns a hashref representing the 
parsed job argument XML.  It actually calls the Helios::Job object's parseArgs()
method and returns its value.

=cut

sub getJobArgs {
	my $self = shift;
	my $job = shift;
	return $job->getArgs() ? $job->getArgs() : $job->parseArgs();
}


=head1 JOB COMPLETION METHODS

These methods should be called in your Helios service class's run() method to 
mark a job as successfully completed, failed, or failed permanently.  They 
actually call the appropriate methods of the given Helios::Job object.

=head2 completedJob($job)

Marks $job as completed successfully.

=cut

sub completedJob {
	my $self = shift;
	my $job = shift;
	return $job->completed();
}


=head2 failedJob($job [, $error][, $exitstatus])

Marks $job as failed.  Allows job to be retried if your subclass supports that 
(see max_retries()).

=cut

sub failedJob {
	my $self = shift;
	my $job = shift;
	my $error = shift;
	my $exitstatus = shift;
	return $job->failed($error, $exitstatus);
}


=head2 failedJobPermanent($job [, $error][, $exitstatus])

Marks $job as permanently failed (no more retries allowed).

=cut

sub failedJobPermanent {
	my $self = shift;
	my $job = shift;
	my $error = shift;
	my $exitstatus = shift;
	return $job->failedNoRetry($error, $exitstatus);
}


=head2 burstJob($metajob)

Given a metajob, burstJob bursts it into its constituent jobs for other Helios workers to process. 
Normally Helios::Service's internal methods will take care of bursting jobs, but the method can be 
overridden if a job service needs special bursting capabilities.

=cut

sub burstJob {
	my $self = shift;
	my $job = shift;
	my $jobnumber = $job->burst();	
	return $jobnumber;
}


=head1 SERVICE CLASS DEFINITION

These are the basic methods that define your Helios service.  The run() method 
is the only one required. 

=head2 run()

This is a default run method for class completeness.  You have to override it 
in your own Helios service class. 

=cut

sub run {
    throw Helios::Error::FatalNoRetry($_[0]->getJobType.': run() method not implemented!'); 
}

=head2 MaxRetries() and RetryInterval()

These methods control how many times a job should be retried if it fails and 
how long the system should wait before a retry is attempted.  If you don't 
defined these, jobs will not be retried if they fail.   

=cut

sub MaxRetries { return undef; }
sub RetryInterval { return undef; }

=head2 JobClass()

Defines which job class to instantiate the job as.  The default is Helios::Job, 
which should be fine for most purposes.  If necessary, however, you can create 
a subclass of Helios::Job and set your JobClass() method to return that 
subclass's name.  The service's work() method will instantiate the job as an 
instance of the class you specified rather than the base Helios::Job.

NOTE:  Please remember that "jobs" in Helios are most often only used to convey 
arguments to services, and usually only contain enough logic to properly parse 
those arguments and mark jobs as completed.  It should be rare to need to 
extend the Helios::Job object.  OTOH, if you are attempting to extend Helios 
itself to provide new abilities and not just writing a normal Helios 
application, you can use JobClass() to use your extended job class rather than 
the default.  

=cut

sub JobClass { return undef; }


1;
__END__


=head1 SEE ALSO

L<helios.pl>, L<Helios::Job>, L<Helios::Error>, L<Helios::ConfigParam>, L<Helios::LogEntry>, 
L<TheSchwartz>, L<XML::Simple>, L<Config::IniFiles>, L<Sys::Syslog>

=head1 AUTHOR

Andrew Johnson, E<lt>lajandy at cpan dotorgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008-9 by CEB Toolbox, Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.0 or,
at your option, any later version of Perl 5 you may have available.

=head1 WARRANTY

This software comes with no warranty of any kind.

=cut

