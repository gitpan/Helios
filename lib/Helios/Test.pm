package Helios::Test;

use 5.008000;
use base qw( Helios::Worker );
use strict;
use warnings;

use Error qw(:try);
use Sys::Syslog qw(:standard :macros);

use Helios::Error;			# pulls in all Helios::Error::* exception types
use Helios::Job;

our $VERSION = '1.19_07';		# necessary for packaging purposes


=head1 NAME

Helios::Test - Helios::Worker subclass for testing purposes

=head1 DESCRIPTION

You can use Helios::Test to test the functionality of Helios collective.  

=over 4

=item 1.

Start a helios.pl daemon to service Helios::Test jobs by issuing:

 helios.pl Helios::Test

at a command prompt.

=item 2.

Submit a job, either from code you're trying to test, or through the Helios::Panoptes Submit Job 
page.

=item 3.

Helios should run the test job.  The job arguments will be parsed and logged as entries in the 
Helios log.  If argument parsing fails, there will be an error in the log instead.

=back

=head1 METHODS

=head2 max_retries() 

=head2 retry_delay()

These are disabled as we don't normally want to retry test jobs.

=cut

#sub max_retries { return 2; }

#sub retry_delay { return 3600; }


=head2 work()

Helios::Test only sets up job processing (via prep() and getJobArgs()) and logs the params passed
to it.

=cut

sub work {
	my $class = shift;
	my Helios::Job $job = shift;
	my $indexerClass = undef;

	# go ahead and instantiate the class we were given
	my $self = new $class;

	try {
		# get the configuration params and job arguments
		$self->prep();
		my $params = $self->getParams();
		my $args = $self->getJobArgs($job);

		if ($self->debug) { print "--JOB ARGUMENTS--\n"; }
		foreach my $arg (sort keys %$args) {
			if ($self->debug) { print uc($arg),'=',$args->{$arg},"|\n"; }
			$self->logMsg($job, LOG_DEBUG, "PARAM: $arg VALUE: ".$args->{$arg});
		}

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

Andrew Johnson, E<lt>ajohnson at ittoolbox dotcomE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008 by CEB Toolbox, Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.0 or,
at your option, any later version of Perl 5 you may have available.

=head1 WARRANTY

This software comes with no warranty of any kind.

=cut

