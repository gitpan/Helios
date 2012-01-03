package Helios::Logger::Internal;

use 5.008;
use base qw(Helios::Logger);
use strict;
use warnings;

use Error qw(:try);

use Helios::LogEntry::Levels qw(:all);

our $VERSION = '2.31_0111';

=head1 NAME

Helios::Logger::Internal - Helios::Logger subclass reimplementing Helios internal logging

=head1 SYNOPSIS
 
 #in helios.ini, enable internal Helios logging (this is default)
 internal_logger=on
 
 #in helios.ini, turn off internal logging
 internal_logger=off


=head1 DESCRIPTION

Helios::Logger::Internal is a refactor of the logging functionality found in 
the Helios 2.23 and earlier Helios::Service->logMsg().  This allows Helios 
services to retain logging functionality found in the previous Helios core 
system while also allowing Helios to be extended to support custom logging 
solutions by subclassing Helios::Logger.

=head1 IMPLEMENTED METHODS

=head2 init()

Helios::Logger::Internal->init() is empty, as an initialization step is unnecessary.

=cut

sub init { }


=head2 logMsg($job, $priority_level, $message)

Implementation of the Helios::Service internal logging code refactored into a 
Helios::Logger class.  

=cut

sub logMsg {
	my $self = shift;
	my $job = shift;
	my $level = shift;
	my $msg = shift;

	my $params = $self->getConfig();
	my $jobType = $self->getJobType();
	my $hostname = $self->getHostname();

    # if this log message's priority is lower than log_priority_threshold,
    # don't bother logging the message
    if ( defined($params->{log_priority_threshold}) &&
        $level > $params->{log_priority_threshold} ) {
        return 1;
    }

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
					priority   => $level,
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
					priority   => $level,
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
	}
	# retry block end
	return 1;
}

=head1 OTHER METHODS

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


1;
__END__


=head1 SEE ALSO

L<Helios::Service>, L<Helios::Logger>

=head1 AUTHOR

Andrew Johnson, E<lt>lajandy at cpan dot orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008 by CEB Toolbox, Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.0 or,
at your option, any later version of Perl 5 you may have available.

=head1 WARRANTY

This software comes with no warranty of any kind.

=cut

