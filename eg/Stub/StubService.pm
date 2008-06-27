package Stub::StubService;

use 5.008000;
use base qw( Helios::Service );
use strict;
use warnings;
use Sys::Syslog qw(:standard :macros);
use Error qw(:try);

use Helios::Error;			# pulls in all Helios::Error::* exception types

our $VERSION = '0.01';		# for packaging purposes


=head1 NAME

Stub::StubService - Helios::Worker subclass to handle [job type here] jobs

=head1 DESCRIPTION

This is a stub class to use as a guide to create new job types for the Helios system (ie new 
Helios::Service subclasses).

=head1 RETRY METHODS

Define max_retries() and retry_delay() methods to determine how many times a job should be retried
if it fails and what the interval between the retries should be.  If you don't define these 
methods, jobs for your service class will not be retried if they fail.

The following declarations set a job to be retried twice at 1 hour intervals.

=cut

sub max_retries { return 2; }
sub retry_delay { return 3600; }


=head2 run($job)

The run() method is the method called to actually run a job.  It is called as an object method, 
and will be passed a Helios::Job object representing the job arguments and other information 
associated with the job to be run.

Once the work for a particular job is done, you should mark the job as either completed, failed, 
or permanently failed.  You can do this by calling the completedJob(), failedJob(), and 
failedJobPermanent() methods.  These methods will call the appropriate Helios::Job methods to 
mark the job as completed.  

Helios expects your service class's run() method to return 0 if the job succeeded or a nonzero 
if it failed.  If your calls to completedJob() or failedJob() are the last statements made in 
your run() method, those methods will return the proper codes for you, so it is suggested that 
they always be the last calls you make in run().

=cut

sub run {
	my $self = shift;
	my $job = shift;
	my $config = $self->getConfig();
	my $args = $self->getJobArgs($job);

	try {

		#### DO YOUR WORK HERE ####

		# example debug log message
		if ($self->debug) { $self->logMsg($job, LOG_DEBUG, "Debugging message (only in debug mode)"); }

		# example normal log message (defaults to LOG_INFO) 
		$self->logMsg($job, "This is a normal log message");

		# if your job completes successfully, you need to mark it was completed
		$self->completedJob($job);

	} catch Helios::Error::InvalidArg with {
		# InvalidArgs are thrown if the job's arguments are somehow wrong
		# it's normal to fail these jobs permanently since if its arguments are wrong it 
		# probably won't ever succeed
		my $e = shift;
		$self->logMsg($job, LOG_ERR, "Invalid job arguments: ".$e->text());
		$self->failedJobPermanent($job,"Invalid job arguments: : ".$e->text());
	} catch Helios::Error::DatabaseError with {
		# DatabaseError is thrown if something happens to the connection to the Helios database
		# (or at your option, some other database error)
		my $e = shift;
		$self->logMsg($job, LOG_ERR, "Database error: ".$e->text.")");
		$self->failedJob($job, $e->text);
	} catch Helios::Error::Warning with {
		# you can throw this in your "WORK" section to denote your job completed, but had warnings
		my $e = shift;
		$self->logMsg($job, LOG_WARNING, "Warning: ".$e->text);
		$self->completedJob($job);
	} catch Helios::Error::Fatal with {
		# you can throw this in your "WORK" section to denote a job that failed
		# (it will be retried if you have defined max_retries() and this job hasn't been retried that many times)
		my $e = shift;
		$self->logMsg($job, LOG_ERR, "FAILED: ".$e->text);
		$self->failedJob($job, $e->text);
	} otherwise {
		# "otherwise" catches unexpected errors that you perhaps didn't throw
		# usually you can mark the jobs as failed and have them retried
		my $e = shift;
		$self->logMsg($job, LOG_ERR, "Unknown error: ".$e->text);
		$self->failedJob($job, $e->text);
	};

}




1;
__END__


=head1 SEE ALSO

L<Helios::Service>, L<helios.pl>, L<TheSchwartz>

=cut
