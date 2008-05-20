#!/usr/bin/perl

use strict;
use warnings;
use CGI ();
use CGI::Carp qw(fatalsToBrowser);

use Error qw(:try);
use Sys::Hostname;
use Sys::Syslog qw(:standard :macros);
use TheSchwartz;

use Helios::Worker;
use Helios::Error;

our $VERSION = '1.19_05';

my $cgi = new CGI;
#print $cgi->header('text/html');

my $type = $cgi->param('type');
my $params = $cgi->param('params');
my $validate = $cgi->param('validate');

our $WORKER = new Helios::Worker;
$WORKER->setHostname(hostname);
$WORKER->getParamsFromIni() or die($WORKER->errstr);	
$WORKER->getParamsFromDb() or die($WORKER->errstr);
my $conf = $WORKER->getParams();

my $job_class;
my @job_handles;

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
		my $arg = $WORKER->parseArgXML($params);
	} otherwise {
		my $e = shift;
		$WORKER->logMsg(LOG_ERR, "Invalid job arguments: $params (".$e.')');
		throw $e;
	};
}

# let's attempt to insert the job into the TheSchwartz job queue
my $databases = [
			{       dsn => $conf->{dsn},
					user => $conf->{user},
					pass => $conf->{password}
			}
		];

my $args = [ $params ];

try {
	my $client = TheSchwartz->new( databases => $databases, verbose => 1 );
	@job_handles = $client->insert($job_class, $args);
#[]? 	$client->set_verbose(1);
} otherwise {
	my $e = shift;
	$WORKER->logMsg(LOG_ERR, "TheSchwartz generated an error?:".$e->text );
	throw $e;
};

print $cgi->header('text/xml');
print <<RESPONSE;
<?xml version="1.0" encoding="UTF-8"?>
<response><status>0</status>
RESPONSE
foreach (@job_handles) {
	print '<jobid>',$_->jobid,"</jobid>";
}
print "</response>";

exit(0);


=head1 FUNCTIONS

=head2 getJobClass($job_type)

Given a job type, getJobClass returns the Perl class associated with that job type in the 
helios_class_map table.

=cut

sub getJobClass {
	my $type = shift;
	my $params = $WORKER->getParams();
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

L<helios_job_submit.pl>, L<helios.pl>, L<TheSchwartz>

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

