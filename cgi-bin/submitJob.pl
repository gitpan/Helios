#!/usr/bin/perl

use strict;
use warnings;
use CGI qw(:cgi);
use CGI::Carp qw(fatalsToBrowser);

use Error qw(:try);
use Sys::Syslog qw(:standard :macros);

use Helios::Job;
use Helios::Service;
use Helios::Error;

our $VERSION = '2.00';

my $cgi = new CGI;
#print $cgi->header('text/html');

my $type = $cgi->param('type');
my $params = $cgi->param('params');
my $validate = $cgi->param('validate');

our $WORKER = new Helios::Service;
$WORKER->prep() or die($WORKER->errstr);
my $conf = $WORKER->getConfig();

my $job_class;
my @job_handles;
my $jobid;

# try to find the job class that will process this type of job
try {
	$job_class = getJobClass($type);
} otherwise {
	my $e = shift;
	$WORKER->logMsg(LOG_ERR, $e->text());
	throw $e;
};

# OK, we have our job class, 
# if indicated, let's check the parameters to make sure they're valid
# (due to performance reasons, this check is turned off unless specifically requested)
if ( defined($validate) && $validate == 1) {
	try {
		my $arg = Helios::Job->parseArgXML($params);
	} otherwise {
		my $e = shift;
		$WORKER->logMsg(LOG_ERR, "Invalid job arguments: $params (".$e.')');
		throw $e;
	};
}

# let's create the Helios::Job object and submit it to the queue
my $hjob = Helios::Job->new();
try {
	$hjob->setConfig($conf);
	$hjob->setFuncname($job_class);
	$hjob->setArgXML($params);
	$jobid = $hjob->submit();
} otherwise {
	my $e = shift;
	$WORKER->logMsg(LOG_ERR,"Job submission error: ".$e->text());
	throw $e;
};

print $cgi->header('text/xml');
print <<RESPONSE;
<?xml version="1.0" encoding="UTF-8"?>
<response>
<status>0</status>
RESPONSE
print '<jobid>',$jobid,"</jobid>";

print "</response>";

exit(0);


=head1 FUNCTIONS

=head2 getJobClass($job_type)

Given a job type, getJobClass returns the Perl class associated with that job type in the 
helios_class_map table.

=cut

sub getJobClass {
	my $type = shift;
	my $params = $WORKER->getConfig();
	my $dsn = $params->{dsn};
	my $user = $params->{user};
	my $password = $params->{password};

	my $dbh = $WORKER->dbConnect($dsn, $user, $password);
	unless ($dbh) { throw Helios::Error::DatabaseError($DBI::errstr); }

	my $sth = $dbh->prepare("SELECT job_class FROM helios_class_map WHERE job_type = ?");
	$sth->execute($type);
	my $result = $sth->fetchrow_arrayref();
	my $job_class = $result->[0];

	unless ( defined($job_class) ) {
		throw Helios::Error::Fatal("Job class not found for type $type");
	}

	return $job_class;
}


=head1 SEE ALSO

L<helios_job_submit.pl>, L<helios.pl>, L<Helios::Service>, L<Helios::Job>

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

