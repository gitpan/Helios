package Helios::Stub;

use 5.008000;
use base qw( Helios::Worker );
use strict;
use warnings;
use Sys::Hostname;
use Sys::Syslog qw(:standard :macros);
use TheSchwartz::Job;
use Error qw(:try);

use Helios::Error;			# pulls in all Helios::Error::* exception types

our $VERSION = '1.19_05';		# necessary for packaging purposes


=head1 NAME

Helios::Stub - Helios::Worker subclass to handle [job type here] jobs

=head1 DESCRIPTION

This is a stub class to use as a guide to create new job types for the Helios system (ie new 
Helios::Worker subclasses).


=head1 TheSchwartz METHODS

The following methods are actually class methods that override those defined by the TheSchwartz 
queuing system.  By overriding them, you define how your jobs will run in the Helios system and 
what actions will be performed.  

The max_retries() and retry_delay() methods determines how many times a job is to be retried if it 
fails, and the amount of time to wait before the job is to be retried (in seconds).  If you want 
your jobs to be retried twice (for 3 total run attempts) and to wait at least an hour before they 
are reattempted, you would define max_retries() and retry_delay() thusly:

 sub max_retries { return 2; }
 sub retry_delay { return 3600; }

TheSchwartz default is to not retry, with no retry delay, so if that's what you want, comment 
out the following sub definitions.

=cut

sub max_retries { return 2; }

sub retry_delay { return 3600; }


=head2 work()

The work() method is called as a class method.  It does the typical prep work for a Helios worker, 
parses the arguments for the TheSchwartz::Job object it was passed, does the necessary work, and 
then marks the job as succeeded or failed.

=cut

sub work {
	my $class = shift;
	my TheSchwartz::Job $job = shift;
	my $indexerClass = undef;

	# go ahead and instantiate the class we were given
	my $self = new $class;

	try {
		# get the configuration params and job arguments
		$self->prep();
		my $params = $self->getParams();
		my $args = $self->getJobArgs($job);


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
		$self->logMsg($job, LOG_ERR, "Class $class FAILED to parse arguments: ".$e->text());
		$self->failedJobPermanent($job,"Class $class FAILED to parse arguments: ".$e->text());
	} catch Helios::Error::DatabaseError with {
		# DatabaseError is thrown if something happens to the connection to the Helios database
		# (or at your option, some other database error)
		my $e = shift;
		$self->logMsg($job, LOG_ERR, "Class $class database error".$e->text.")");
		$self->failedJob($job, $e->text."(Class $class)");
	} catch Helios::Error::Warning with {
		# you can throw this in your "WORK" section to denote your job completed, but had warnings
		my $e = shift;
		$self->logMsg($job, LOG_WARNING, "Class $class WARNING: ".$e->text);
		$self->completedJob($job);
	} catch Helios::Error::Fatal with {
		# you can throw this in your "WORK" section to denote a job that failed
		# (it will be retried if you have defined max_retries() and this job hasn't been retried that many times)
		my $e = shift;
		$self->logMsg($job, LOG_ERR, "Class $class FAILED: ".$e->text);
		$self->failedJob($job, $e->text."(Class $class)");
	} otherwise {
		# "otherwise" catches unexpected errors that you perhaps didn't throw
		# usually you can mark the jobs as failed and have them retried
		my $e = shift;
		$self->logMsg($job, LOG_ERR, "Class $class FAILED with unknown error: ".$e->text);
		$self->failedJob($job, $e->text."(Class $class)");
	};

}




1;
__END__


=head1 SEE ALSO

L<Helios::Worker>

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

