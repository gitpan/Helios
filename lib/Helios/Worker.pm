package Helios::Worker;

use 5.008000;
use base qw( TheSchwartz::Worker );
use strict;
use warnings;
use Sys::Hostname;
use Sys::Syslog qw(:standard :macros);

use Config::IniFiles;
use Data::Dumper;
use DBI;
use Error qw(:try);
use TheSchwartz;
use TheSchwartz::Job;
require XML::Simple;
$XML::Simple::PREFERRED_PARSER = 'XML::Parser';

use Helios::Job;
use Helios::Error;

our $VERSION = '1.20_12';


=head1 NAME

Helios::Worker - base class for workers in the Helios job processing system [DEPRECATED]

=head1 DESCRIPTION

Helios::Worker has been DEPRECATED and is included only to support Helios 1.x applications.  
See L<Helios::Service> for creating new Helios worker classes/services.

Helios::Worker is the base class for all worker classes intended to be run by the Helios
parallel job processing system.  It encapsulates functions of the underlying TheSchwartz job 
queue system and provides additional methods to handle configuration, job argument parsing, 
logging, and other functions.

A Helios::Worker subclass must implement the work() method.  It may also implement the 
max_retries() and retry_delay() methods if failed jobs of your class should be retried.  
The other Helios::Worker methods are available for use during job processing.  

When job processing is completed, the job should be marked as completed successfully or failed 
by using the completedJob(), failedJob(), and failedJobPermanent() methods.  If your worker 
class supports OVERDRIVE mode operation, it should also call the shouldExitOverdrive() method 
at the end of your work() method and explicitly exit() if shouldExitOverdriver() returns a true 
value.  (If supporting OVERDRIVE, your worker class should also explicitly exit() if job processing
fails to prevent errors from affecting future jobs.)

=head1 TheSchwartz METHODS

The following 3 methods are used by the underlying TheSchwartz job queuing system to determine what
work is to be performed and, a job fails, how it should be retried.

=head2 max_retries()

Controls how many times a job will be retried.  Not used in the base Helios::Worker class.

=head2 retry_delay()

Controls how long (in secs) before a failed job will be retried.  Not used in the base 
Helios::Worker class.

If you want your worker class to retry a failed job twice with an hour interval between each
try, you would define max_retries() and retry_delay thusly:

 sub max_retries { return 2; }
 sub retry_delay { return 3600; }

=cut

# sub max_retries { return 2; }

# sub retry_delay { return 10; }


=head2 work()

The work() method is essentially the main() function for your worker class.  When a worker process is 
launched by the helios.pl worker daemon, the process calls its work() method and passes it the job 
information for an available job.

A work() method should take the general form:

 sub work {
     my $class = shift;
	 my $job = shift;
	 my $self = $class->new();

	 try {
		$self->prep();
		my $params = $self->getParams();
		my $job_args = $self->getJobArgs($job);

		# DO WORK HERE #

		$self->completedJob($job);
     } catch Helios::Error::Warning {
		 my $e = shift;
		 $self->logMsg($job, LOG_WARN, $e->text);
         $self->completedJob($job, "Job completed with warning ".$e->text);
	 } catch Helios::Error::Fatal {
		 my $e = shift;
		 $self->logMsg($job, LOG_ERR, $e->text);
		 $self->failedJob($job, "Job failed ".$e->text);
     } otherwise {
		 my $e = shift;
		 $self->logMsg($job, LOG_ERR, $e->text);
		 $self->failedJob($job, "Job failed with unknown error ".$e->text);
	 };
 }

NOTE:  It should be noted that although work() is called as a class method, the Helios::Worker 
methods expect the worker to be instantiated as an object.  Instantiating the object from the class
passed in (as on the 3rd line above) should take care of this discrepancy.

You can use the above as a template for all of your worker classes' work() methods, as they will 
all need to perform the same basic steps:  get the class and job; instantiate the class; call 
prep(), getParams(), and getJobArgs() to set up the worker object, retrieve configuration 
parameters, and parse job arguments; do whatever work is to be done, marking the job as completed 
if successful; logging the error and marking the job as failed if an error occurs.

To support OVERDRIVE mode, a few additions need to be made:

 sub work {
     my $class = shift;
	 my $job = shift;
	 my $self = $class->new();

	 try {
		$self->prep();
		my $params = $self->getParams();
		my $job_args = $self->getJobArgs($job);

		# DO WORK HERE #

		$self->completedJob($job);
     } catch Helios::Error::Warning {
		 my $e = shift;
		 $self->logMsg($job, LOG_WARN, $e->text);
         $self->completedJob($job, "Job completed with warning ".$e->text);
	 } catch Helios::Error::Fatal {
		 my $e = shift;
		 $self->logMsg($job, LOG_ERR, $e->text);
		 $self->failedJob($job, "Job failed ".$e->text);
         exit(1);
     } otherwise {
		 my $e = shift;
		 $self->logMsg($job, LOG_ERR, $e->text);
		 $self->failedJob($job, "Job failed with unknown error ".$e->text);
         exit(1);
	 };

     if ($self->shouldExitOverdrive()) {
		 $self->logMsg(LOG_INFO, "$class worker exited overdrive");
         exit(0);
     }
 }

Note the strategic additions of exit() calls and the shouldExitOverdrive() check at the end of the 
method.  That should help prevent problems with one job spilling over into the next, and also allow
the helios.pl daemons to better control the worker child processes.

=cut

sub work {
	my $class = shift;
	my Helios::Job $job = shift;

	# get the params (db setup) and args (contribID)
	# get the database (ProfNet)
	my $self = new $class;

	try {
		$self->prep();
		my $params = $self->getParams();
		my $args = $self->parseArgXML( $job->arg()->[0] );

		$self->logMsg($job, LOG_WARNING, "This is the work() method from the Helios::Worker base class; did you forget to override work() in your worker class?");

		# successful
		$self->completedJob($job);
	} otherwise {
		my $e = shift;
		$self->logMsg($job, LOG_ERR, "Class $class FAILED: ".$e->text);
		$self->failedJobPermanent($job, $e->text."(Class $class)");
	};

}


=head1 ACCESSOR METHODS

These accessors will be needed by all subclasses of Helios::Worker.

 get/setClient()
 get/setJobType()
 get/setParams()
 get/setIniFile()
 get/setHostname()
 errstr()
 debug()

Most of these are handled behind the scenes simply by calling the prep() method.

After calling prep(), calling getParams() will return a hashref of all the configuration parameters
relevant to this worker class on this host.

If debug mode is enabled (the HELIOS_DEBUG env var is set to 1), debug() will return a true value, 
otherwise, it will be false.  Some of the Helios::Worker methods will honor this value and log 
extra debugging messages either to the console or the Helios log (helios_log_tb table).  You can 
also use it within your own worker classes to enable/disable debugging messages or behaviors.

=cut

sub setClient { $_[0]->{client} = $_[1]; }
sub getClient { return $_[0]->{client}; }

sub setJobType { $_[0]->{jobType} = $_[1]; }
sub getJobType { return $_[0]->{jobType}; }

sub setParams { $_[0]->{params} = $_[1]; 
#	print "--PARAMS RESET--\n";	#[]t
#	foreach (keys %{$_[0]->{params}}) { print "KEY: $_; PARAM: ",$_[0]->{params}->{$_},"\n"; }	#[]t
}
sub getParams { return $_[0]->{params}; }

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


=head1 OTHER METHODS

=head2 prep()

The prep() method is designed to call all the various setup routines needed to 
get the worker ready to do useful work.  It:

=over 4

=item * 

Pulls in the contents of the HELIOS_DEBUG and HELIOS_INI env vars, and sets the appropriate 
instance variables if necessary.

=item *

Calls the getParamsFromIni() method to read the appropriate configuration parameters from the 
INI file.

=item *

Calls the getParamsFromDb() method to read the appropriate configuration parameters from the 
Helios database.

=back

Normally it returns a true value if successful, but if one of the getParamsFrom*() methods throws 
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
	$self->getParamsFromIni();
	$self->getParamsFromDb();
	return 1;
}


=head2 getParamsFromIni([$inifile])

The getParamsFromIni() method opens the helios.ini file, grabs global params and params relevant to
the current worker class, and returns them in a hash to the calling routine.  It also sets the class's 
internal {params}, so the config parameters are available via the getParams() method.

Typically worker classes will call this once near the start of processing to pick up any relevant 
parameters from the helios.ini file.  However, calling the prep() method takes care of this for 
you, and is the preferred method.

=cut

sub getParamsFromIni {
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
			$self->errstr("INI configuration file not specified.");
			return undef;
		}
	}

	if ( $self->debug() ) { print "inifile: $inifile\nclass:$jobtype\n"; }		
	unless (-r $inifile) { $self->errstr("INI read error: $!"); return undef; }

	my $ini = new Config::IniFiles( -file => $inifile );

	# global must exist; it's where the helios db is declared
	if ($ini->SectionExists("global") ) {
		foreach ( $ini->Parameters("global") ) {
			$params{$_} = $ini->val("global", $_);
		}
	} else {
		print STDERR "Section [global] doesn't exist in config file $inifile";
		$self->errstr("Section [global] doesn't exist in config file $inifile");
		return undef;
	}
	
	# if there's a section specifically for this worker class, read it too
	# (it will effectively override the global section, BTW)
	if ( $ini->SectionExists($jobtype) ) {
		foreach ( $ini->Parameters($jobtype) ) {
			$params{$_} = $ini->val($jobtype, $_);
		}
	}

	$self->setParams(\%params);
	return %params;
}


=head2 getParamsFromDb()

The getParamsFromDb() method connects to the Helios database, retrieves params relevant to the 
current worker class, and returns them in a hash to the calling routine.  It also sets the class's 
internal {params}, so the config parameters are available via the getParams() method.

Typically worker classes will call this once near the start of processing to pick up any relevant 
parameters from the helios.ini file.  However, calling the prep() method takes care of this for 
you.

There's an important subtle difference between getParamsFromIni() and getParamsFromDb():  
getParamsFromIni() erases any previously set parameters from the class's internal {params} hash, 
while getParamsFromDb() merely updates it.  This is due to the way helios.pl uses the methods:  
the INI file is only read once, while the database is repeatedly checked for configuration 
updates.  For individual worker classes, the best thing to do is just call the prep() method; it 
will take care of things for the most part.

=cut

sub getParamsFromDb {
	my $self = shift;
	my $params = $self->getParams();
	my $hostname = $self->getHostname();
	my $jobtype = $self->getJobType();

	if ($self->debug) { print "Retrieving params for ".$self->getJobType()." on ".$self->getHostname()."\n"; }

	try {

		# get db connection info
		my $dbh = $self->dbConnect();

		# params with host = * are pulled first
		my $sth1 = $dbh->prepare("SELECT * FROM helios_params_tb WHERE host = '*' AND worker_class = ?");

		$sth1->execute($jobtype);

		while (my $res1 = $sth1->fetchrow_hashref() ) {
			$params->{$res1->{param}} = $res1->{value};
		}

		# params with explicit host overrride host = '*' params
		my $sth2 = $dbh->prepare("SELECT * FROM helios_params_tb WHERE host = ? AND worker_class = ?");

		$sth2->execute($hostname, $jobtype);

		while (my $res2 = $sth2->fetchrow_hashref() ) {
			$params->{$res2->{param}} = $res2->{value};
		}

		$sth1->finish();
		$sth2->finish();

	} otherwise {
		throw Helios::Error::DatabaseError($DBI::errstr);
	};

	$self->setParams($params);
	return %{$params};
}


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
	my $params = $self->getParams();

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


=head2 jobsWaiting() 

Scans the job queue for jobs that are ready to run.  Returns the number of jobs waiting.  Only 
meant for use with the helios.pl program.

=cut

sub jobsWaiting {
	my $self = shift;
	my $params = $self->getParams();
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


=head2 logMsg([$job,] [$priority,] $msg)

Record a message in the log.  Though originally only meant to log to a syslogd facility (via 
Sys::Syslog), it now also logs the message to the Helios database.

In addition to the log message, there are two optional parameters:

=over 4

=item $job

The current job being processed.  If specified, the jobid will be logged in the database along 
with the message.

=item $priority

The priority of the message as defined by syslog.  These are really integers, but if you import 
the syslog constants [use Sys::Syslog qw(:macros)] into your namespace, your logMsg() calls will 
be much more readable.  Refer to the L<Sys::Syslog/CONSTANTS> manpage for a list of valid syslog
constants.  LOG_DEBUG, LOG_INFO, LOG_WARNING, and LOG_ERR are the most commonly used with Helios; 
LOG_INFO is the default.

=back

In addition, there are two INI file options used to configure logging.  These will be passed to 
syslogd when logMsg() calls Sys::Syslog::openlog():

=over 4

=item log_facility

The syslog facility to log the message to.

=item log_options

Any logging options to specify to syslogd.  Again, see the L<Sys::Syslog> manpage.

=back

For database logging, the host, process id, and worker class are automatically recorded in the 
database with your log message.  If you supplied either a Job object or a priority, 
the jobid and/or priority will also be recorded with your message.

=cut

sub logMsg {
	my $self = shift;
	my $priority;
	my $msg;
	my $job;

	# if the first parameter is a TheSchwartz::Job object, log extra info
	if ( ref($_[0]) && $_[0]->isa('TheSchwartz::Job') ) {
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
	
	my $params = $self->getParams();
	my $jobType = $self->getJobType();
	my $hostname = $self->getHostname();

	openlog($jobType, $params->{log_options}, $params->{log_facility});
	syslog($priority, $msg);
	closelog();

	# log to database

	try{
		my $dbh = $self->dbConnect();
		my $sth = $dbh->prepare("INSERT INTO helios_log_tb (log_time, host, process_id, funcid, jobid, job_class, priority, message) VALUES (?,?,?,?,?,?,?,?)");

		if ( defined($job) ) {
			$sth->execute(time(), $hostname, $$, $job->funcid, $job->jobid, $jobType, $priority, $msg);
		} else {
			$sth->execute(time(), $hostname, $$, undef, undef, $jobType, $priority, $msg);
		}
	} otherwise {
		throw Helios::Error::DatabaseError($DBI::errstr);
	};

	return 1;
}


=head2 parseArgXML($xml) 

Given a string of XML, parse it into a mixed hash/arrayref structure.  This uses XML::Simple.

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

Call getJobArgs() to pick the Helios job arguments (the first element of the job->args() array) 
from the Schwartz job object, parse the XML into a Perl data structure (via XML::Simple) and 
return the structure to the calling routine.  

This is really a convenience method created because 

 $args = $self->parseArgXML( $job->arg()->[0] );

looks nastier than it really needs to be.

=cut

sub getJobArgs {
	my $self = shift;
	my $job = shift;
	return $self->parseArgXML( $job->arg()->[0] );
}


=head2 shouldExitOverdrive()

Determine whether or not to exit if OVERDRIVE mode is enabled.  The config params will be checked for 
HOLD, HALT, or OVERDRIVE values.  If HALT is defined, HOLD == 1, or OVERDRIVE == 0, this method returns a
true value, indicating the worker should exit().

=cut

sub shouldExitOverdrive {
	my $self = shift;
	my $params = $self->getParams();
	if ( defined($params->{HALT}) ) { return 1; }
	if ( defined($params->{HOLD}) && $params->{HOLD} == 1) { return 1; }
	return 0;
}


=head1 JOB CONTROL METHODS

TheSchwartz::Job methods do not provide adequate logging of job completion for our purposes, so 
these methods encapsulate extra 'Helios' things we want to do in addition to the normal 
'TheSchwartz' things.

The functionality of these methods will be refactored into the new Helios::Job class in the future.

=head2 completedJob($job)

Marks $job as completed successfully.

=cut

sub completedJob {
	my $self = shift;
	my $job = shift;

	my $sql = <<JOBCSQL;
INSERT INTO helios_job_history_tb
	(jobid, funcid, arg, uniqkey, insert_time, run_after, grabbed_until, priority, coalesce, complete_time, exitstatus)
VALUES
	(?,?,?,?,?,?,?,?,?,?,?)
JOBCSQL

	try {
		my $dbh = $self->dbConnect();
		$dbh->do($sql, undef, $job->jobid, $job->funcid, $job->arg()->[0], $job->uniqkey, $job->insert_time, 
				$job->run_after, $job->grabbed_until, $job->priority, $job->coalesce, time(), 0);
	} otherwise {
		throw Helios::Error::DatabaseError($DBI::errstr);
	};

	$job->completed();
	return 1;
}


=head2 failedJob($job [, $error])

Marks $job as failed.  Allows job to be retried if your worker class supports that 
(see max_retries()).

=cut

sub failedJob {
	my $self = shift;
	my $job = shift;
	my $error = shift;
	my $exitstatus = shift;

	my $sql = <<JOBFSQL;
INSERT INTO helios_job_history_tb
	(jobid, funcid, arg, uniqkey, insert_time, run_after, grabbed_until, priority, coalesce, complete_time, exitstatus)
VALUES
	(?,?,?,?,?,?,?,?,?,?,?)
JOBFSQL

	try {
		my $dbh = $self->dbConnect();
		$dbh->do($sql, undef, $job->jobid, $job->funcid, $job->arg()->[0], $job->uniqkey, $job->insert_time, 
				$job->run_after, $job->grabbed_until, $job->priority, $job->coalesce, time(), 1);
	} otherwise {
		$job->failed($error, $exitstatus);
		throw Helios::Error::DatabaseError($DBI::errstr);
	};

	$job->failed($error, $exitstatus);
	return 1;
}


=head2 failedJobPermanent($job [, $error])

Marks $job as permanently failed (no more retries allowed).

=cut

sub failedJobPermanent {
	my $self = shift;
	my $job = shift;
	my $error = shift;
	my $exitstatus = shift;

	my $sql = <<JOBFPSQL;
INSERT INTO helios_job_history_tb
	(jobid, funcid, arg, uniqkey, insert_time, run_after, grabbed_until, priority, coalesce, complete_time, exitstatus)
VALUES
	(?,?,?,?,?,?,?,?,?,?,?)
JOBFPSQL

	try {
		my $dbh = $self->dbConnect();
		$dbh->do($sql, undef, $job->jobid, $job->funcid, $job->arg()->[0], $job->uniqkey, $job->insert_time, 
				$job->run_after, $job->grabbed_until, $job->priority, $job->coalesce, time(), 1);
	} otherwise	{
		$job->permanent_failure($error, $exitstatus);
		throw Helios::Error::DatabaseError($DBI::errstr);
	};

	$job->permanent_failure($error, $exitstatus);
	return 1;
}


=head1 HELIOS 2.0 COMPATIBILITY METHODS

The following methods were changed/introduced in the new 2.0 API and are here to maintain 
compatibility with the helios.pl daemon for legacy applications.

=cut

sub setConfig { return setParams(@_); }
sub getConfig { return getParams(@_); }
sub getConfigFromIni { return getParamsFromIni(@_); }
sub getConfigFromDb { return getParamsFromDb(@_); }



1;
__END__


=head1 SEE ALSO

L<TheSchwartz>, L<XML::Simple>, L<Config::IniFiles>

=head1 AUTHOR

Andrew Johnson, E<lt>ajohnson@ittoolbox.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008 by CEB Toolbox, Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.0 or,
at your option, any later version of Perl 5 you may have available.

=head1 WARRANTY

This software comes with no warranty of any kind.

=cut

