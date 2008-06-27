package Helios::Service;

use 5.008000;
use base qw( TheSchwartz::Worker );
use strict;
use warnings;
use Sys::Hostname;
use Sys::Syslog qw(:standard :macros);
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

our $VERSION = '1.90_25';
our $MAX_RETRIES = 0;
our $RETRY_INTERVAL = 0;


=head1 NAME

Helios::Service - base class for services/worker classes in the Helios job processing system

=head1 DESCRIPTION

Helios::Service is the base class for all services (aka worker classes) intended to be run by the 
Helios parallel job processing system.  It handles the underlying TheSchwartz job queue system and 
provides additional methods to handle configuration, job argument parsing, logging, and other 
functions.

A Helios::Service subclass must implement only one method:  the run() method.  The run() method 
will be passed a Helios::Job object representing the job to performed.  The run() method should 
mark the job as completed successfully, failed, or permanently failed (by calling completedJob(),
failedJob(), or failedJobPermanent(), respectively) before it ends.  

=head1 TheSchwartz HANDLING METHODS

The following 3 methods are used by the underlying TheSchwartz job queuing system to determine what
work is to be performed and, a job fails, how it should be retried.

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

sub work {
	my $class = shift;
	my $schwartz_job = shift;
	my $job = Helios::Job->new($schwartz_job);
	my $return_code;
	my $args;

	# instantiate the service class into a worker
	my $self = new $class;
	$MAX_RETRIES = $self->max_retries();
	$RETRY_INTERVAL = $self->retry_delay();
	if ($self->debug) {
		print "max_retries: ",max_retries(),"\n";
		print "retry_delay: ",retry_delay(),"\n";
	}

	try {
		$self->prep();
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
	if ( defined($args->{metajob}) && $args->{metajob} == 1 ) {
		$self->logMsg($job, LOG_INFO, 'Job '.$job->getJobid.' is a metajob.  Bursting...');
		try {
			my $numberOfJobs = $self->burstJob($job);
			$self->logMsg($job, LOG_INFO, 'Job '.$job->getJobid.' burst into '.$numberOfJobs.' jobs');
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
		$self->logMsg(LOG_INFO,"Class $class exited (downshift)");
		exit(0);
	}
}


=head1 ACCESSOR METHODS

These accessors will be needed by subclasses of Helios::Service.

 get/setConfig()
 get/setHostname()
 get/setIniFile()
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

# need for helios.pl logging	
sub setJobType { $_[0]->{jobType} = $_[1]; }
sub getJobType { return $_[0]->{jobType}; }

sub setConfig { $_[0]->{config} = $_[1]; }
sub getConfig { return $_[0]->{config}; }

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

It does set the job type for the object (available via the getJobType() method)

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

=head2 prep()

The prep() method is designed to call all the various setup routines needed to 
get the worker ready to do useful work.  It:

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

	# pull params from environment
	$self->setHostname(hostname);
	if ( defined($ENV{HELIOS_DEBUG}) ) {
		$self->debug($ENV{HELIOS_DEBUG});
	}
	if ( defined($ENV{HELIOS_INI}) && 
		!defined($self->getIniFile) ) {
		$self->setIniFile($ENV{HELIOS_INI});
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

Typically job service classes will call this once near the start of processing to pick up any relevant 
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
		} elsif (-r './helios.ini' ) {
			$inifile = './helios.ini';
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
	
	# if there's a section specifically for this worker class, read it too
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
internal {config} hasref, so the config parameters are available via the getConfig() method.

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


=head2 jobsWaiting() 

Scans the job queue for jobs that are ready to run.  Returns the number of jobs waiting.  Only 
meant for use with the helios.pl service daemon.

=cut

sub jobsWaiting {
	my $self = shift;
	my $params = $self->getConfig();
	my $jobType = $self->getJobType();

	try {

		my $dbh = $self->dbConnect($params->{dsn}, $params->{user}, $params->{password});
		unless ($dbh) { throw Helios::Error::DatabaseError($self->errstr); }

		# get the funcid 
		my $sth1 = $dbh->prepare("SELECT funcid FROM funcmap WHERE funcname = ?");

		$sth1->execute($jobType);

		my $result1 = $sth1->fetchrow_arrayref();
		unless ( defined($result1->[0]) ) { 
			$self->errstr("funcname $jobType not found!"); return undef; 
		}
		my $funcid = $result1->[0];

		my $sql2 = <<JWSQL2;
SELECT COUNT(*)
FROM job
WHERE funcid = ?
	AND (run_after < ?)
	AND (grabbed_until < ?)
JWSQL2
		my $sth2 = $dbh->prepare($sql2);

		my $current_time = time();
		$sth2->execute($result1->[0], $current_time, $current_time);
		my $result2 = $sth2->fetchrow_arrayref();
		unless ( defined($result2->[0]) ) {
			$self->errstr("Received NULL value in jobsWaiting() for funcname $jobType!"); return undef; 
		}
		$sth1->finish();
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

Determine whether or not to exit if OVERDRIVE mode is enabled.  The config params will be checked 
for HOLD, HALT, or OVERDRIVE values.  If HALT is defined or HOLD == 1 this method will return a 
true value, indicating the worker process should exit().

=cut

sub shouldExitOverdrive {
	my $self = shift;
	my $params = $self->getConfig();
	if ( defined($params->{HALT}) ) { return 1; }
	if ( defined($params->{HOLD}) && $params->{HOLD} == 1) { return 1; }
	return 0;
}


=head1 METHODS AVAILABLE TO SERVICE SUBCLASSES

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
		if ( $DBI::errstr ) { 
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

Record a message in the Helios log.  If a syslogd log facility is set in helios.ini (via the 
syslog_facility option), the message is also logged into the specified syslogd facility.

In addition to the log message, there are two optional parameters:

=over 4

=item $job

The current Helios::Job object being processed.  If specified, the jobid will be logged in the 
database along with the message.

=item $priority

The priority of the message as defined by syslogd.  These are really integers, but if you import 
the syslog constants [use Sys::Syslog qw(:macros)] into your namespace, your logMsg() calls will 
be much more readable.  Refer to the L<Sys::Syslog/CONSTANTS> manpage for a list of valid syslog
constants.  LOG_DEBUG, LOG_INFO, LOG_WARNING, and LOG_ERR are the most common used with Helios; 
LOG_INFO is the default.

=back

In addition, there are two INI file options used to configure logging.  These will be passed to 
syslogd when logMsg() calls Sys::Syslog::openlog():

=over 4

=item syslog_facility

The syslog facility to log the message to.

=item syslog_options

Any logging options to specify to syslogd.  Again, see the L<Sys::Syslog> manpage.

=back

For database logging, the host, process id, and job service class are automatically recorded in 
the database with your log message.  If you supplied either a Job object or a priority, 
the jobid and/or priority will also be recorded with your log message.

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

	# log the message to syslog IF log_facility was set
	if ( defined($params->{syslog_facility}) ) {
		openlog($jobType, $params->{syslog_options}, $params->{syslog_facility});
		syslog($priority, $msg);
		closelog();
	}

	# log to database
	my $retries = 0;
	my $retry_limit = 3;
	RETRY:
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
				sleep 5;
				next RETRY;
			}
		};
	# retry block end
	return 1;
}


=head2 parseArgXML($xml) [DEPRECATED]

Given a string of XML, parse it into a mixed hash/arrayref structure.  This uses XML::Simple.

This method is DEPRECATED; its functionality has been moved to Helios::Job->parseArgXML().

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

Given a Helios::Job object, getJobArgs() returns a hashref representing the parsed job argument 
XML.  It actually calls the Helios::Job object's parseArgs() method and returns its value.

=cut

sub getJobArgs {
	my $self = shift;
	my $job = shift;
	return $job->getArgs() ? $job->getArgs() : $job->parseArgs();
}


=head1 JOB METHODS

These methods should be called in the subclass's run() method to mark a job as successfully 
completed, failed, or failed permanently.  They actually call the appropriate methods of the given 
Helios::Job object.

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



1;
__END__


=head1 SEE ALSO

L<helios.pl>, L<Helios::Job>, L<Helios::Error>, L<Helios::ConfigParam>, L<Helios::LogEntry>, 
L<TheSchwartz>, L<XML::Simple>, L<Config::IniFiles>

=head1 AUTHOR

Andrew Johnson, E<lt>ajohnson at ittoolbox dotcomE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008 by CEB Toolbox, Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.0 or,
at your option, any later version of Perl 5 you may have available.

=head1 WARRANTY

This software comes with no warranty of any kind.

=cut

