package Helios::TestService;

use 5.008000;
use base qw( Helios::Service );
use strict;
use warnings;

use Error qw(:try);
use Sys::Syslog qw(:standard :macros);

use Helios::Error;			# pulls in all Helios::Error::* exception types
use Helios::Job;

our $VERSION = '2.00';	# necessary for packaging purposes

=head1 NAME

Helios::TestService - Helios::Service subclass for testing purposes

=head1 DESCRIPTION

You can use Helios::TestService to test the functionality of your Helios collective.  

=over 4

=item 1.

Start a helios.pl daemon to service Helios::TestService jobs by issuing:

 helios.pl Helios::TestService

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
#sub retry_delay { return 60; }

=head2 run()

The run() method just logs the arguments passed to the job.

=cut

sub run {
	my $self = shift;
	my $job = shift;
	my $config = $self->getConfig();
	my $args = $job->getArgs();

	try {
		if ($self->debug) {
			print "--CONFIG PARAMS--\n";
			foreach (keys %$config) {
				print $_,'=',$config->{$_},"\n";
			}
		}

		if ($self->debug) { print "--JOB ARGUMENTS--\n"; }
		foreach my $arg (sort keys %$args) {
			if ($self->debug) { print uc($arg),'=',$args->{$arg},"|\n"; }
			$self->logMsg($job, LOG_DEBUG, "PARAM: $arg VALUE: ".$args->{$arg});
		}
		if ( defined($args->{failure}) ) {
			throw Helios::Error::Fatal("Artificially throwing error here");
		}
		# if your job completes successfully, you need to mark it was completed
		$self->completedJob($job);

	} catch Helios::Error::Warning with {
		# you can throw this in your "WORK" section to denote your job completed, but had warnings
		my $e = shift;
		$self->logMsg($job, LOG_WARNING, "Class $self WARNING: ".$e->text);
		$self->completedJob($job);
	} catch Helios::Error::Fatal with {
		# you can throw this in your "WORK" section to denote a job that failed
		# (it will be retried if you have defined max_retries() and this job hasn't been retried that many times)
		my $e = shift;
		$self->logMsg($job, LOG_ERR, "Class $self FAILED: ".$e->text);
		$self->failedJob($job, $e->text."(Class $self)",835);
	} otherwise {
		# "otherwise" catches unexpected errors that you perhaps didn't throw
		# usually you can mark the jobs as failed and have them retried
		my $e = shift;
		$self->logMsg($job, LOG_ERR, "Class $self FAILED with unexpected error: ".$e->text);
		$self->failedJob($job, $e->text."(Class $self)");
	};

}




1;
__END__


=head1 SEE ALSO

L<Helios::Service>

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

