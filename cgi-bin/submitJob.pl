#!/usr/bin/env perl

use 5.008;
use strict;
use warnings;
use CGI qw(:cgi -debug);
use CGI::Carp 'fatalsToBrowser';

use Helios::Job;
use Helios::Service;
use Helios::LogEntry::Levels ':all';

our $VERSION = '2.30_5041';

=head1 NAME

submitJob.pl - CGI script to receive jobs for Helios via HTTP POST

=head1 DESCRIPTION

#[] more doc!

=head1 SUPPORTED FORMATS

#[] more documentation here later

=head2 FORM ENCODED

#[] more doc!

=head2 XML POSTDATA

Example of submitting a Helios job by POSTing an XML stream:

 #!/usr/bin/env perl 
 use strict;
 use warnings;
 use LWP::UserAgent;
 use HTTP::Request::Common;
 my $ua = LWP::UserAgent->new();
 my $jobXML = <<ENDXML;
 <?xml version="1.0" encoding="UTF-8"?>
 <job type="Helios::TestService">
 <params> 
 	<arg1>a posted test job!</arg1>
 	<note>this time without the class map</note>
 </params>
 </job>
 ENDXML

 my $r = $ua->request(POST 'http://localhost/cgi-bin/submitJob.pl',
		Content_Type => 'text/xml',
		Content => $message
 );
 print $response->as_string;

=head1 RESPONSE

 HTTP/1.1 200 OK
 Connection: close
 Date: Fri, 16 Dec 2011 04:24:30 GMT
 Server: Apache/2.2.14 (Ubuntu)
 Vary: Accept-Encoding
 Content-Type: text/xml; charset=ISO-8859-1
 Client-Date: Fri, 16 Dec 2011 04:24:30 GMT
 Client-Peer: 127.0.0.1:80
 Client-Response-Num: 1
 Client-Transfer-Encoding: chunked

 <?xml version="1.0" encoding="UTF-8"?>
 <response>
 <status>0</status>
 <jobid>42</jobid>
 </response>


=cut

# grab the CGI params (we may not have any)
my $cgi = CGI->new();
my $type = $cgi->param('type');
my $params = $cgi->param('params');

# setup Helios service for config/logging/etc.
my $Service = new Helios::Service;
$Service->prep() or die($Service->errstr);
my $HeliosConfig = $Service->getConfig();

# we're going to fill these in
my $jobClass;
my $argXML;
my $job;
my $jobid;

# we were either given a bunch of XML in POSTDATA
# or a multipart MIME-encoded form
if ( defined($type) && defined($params) ) {
	# ok, the submission was made old-school,
	# via multi-part form
	$jobClass = lookupJobClass($type);
	$argXML = $params;
} elsif ( defined($cgi->param('POSTDATA')) ) {
	# submission was just a POSTed XML stream
	# parse the XML to get the type, then
	# use the type to get the job class
	$argXML = $cgi->param('POSTDATA');
	$type = parseArgXMLForType($argXML);
	$jobClass = lookupJobClass($type);
} else {
	$Service->logMsg(LOG_ERR, 'submitJob.pl ERROR: submit request failed to submit job type and/or arguments');
	die('submitJob.pl ERROR: submit request failed to submit job type and/or arguments');
}

# we have job argument XML and the class it's destined for
# so it's submission time!
eval {
	$job = Helios::Job->new();
	$job->setConfig($HeliosConfig);
	$job->setFuncname($jobClass);	
	$job->setArgXML($argXML);
	$jobid = $job->submit();
} or do {
	$Service->logMsg(LOG_ERR, $@);
	die($@);
};

# if we encountered no errors, the job was submitted successfully
# send a nice response message to the client
print $cgi->header('text/xml');
print <<RESPONSE;
<?xml version="1.0" encoding="UTF-8"?>
<response>
<status>0</status>
<jobid>$jobid</jobid>
</response>
RESPONSE

# DONE!
exit(0);


=head1 FUNCTIONS

=head2 lookupJobClass($type)

Given a job type, lookupJobClass() queries the HELIOS_CLASS_MAP table to 
determine if a Helios service class is associated with that job type.  If 
there is, the function returns that service class.  If it isn't, the original 
type is assumed to be the name of the desired service class, and it is 
returned to the caller instead.

=cut

sub lookupJobClass {
	my $type = shift;
	my $dbh = $Service->dbConnect();
	my $r = $dbh->selectrow_arrayref("select job_class from helios_class_map where job_type = ?", 
			undef, $type);
	if ( defined($r) && defined($r->[0]) ) {
		return $r->[0];
	} else {
		return $type;
	}
}


=head2 parseArgXMLForType

=cut

sub parseArgXMLForType {
	my $parsedXml = Helios::Job->parseArgXML($_[0]);
	my $type;
#t	use Data::Dumper;
#	print "PARSED ARGS:\n";
#	print Dumper($parsedXml);
	if ( defined($parsedXml->{job}->[0]->{type}) ) {
		return $parsedXml->{job}->[0]->{type};
	} else {
		$Service->logMsg(LOG_ERR,"submitJob.pl ERROR: type attribute not specified in XML stream");
		die("submitJob.pl ERROR: type attribute not specified in XML stream");
	}
}

=head1 SEE ALSO

L<helios_job_submit.pl>, L<helios.pl>, L<Helios::Service>, L<Helios::Job>

=head1 AUTHOR

Andrew Johnson, E<lt>lajandy at cpan dot orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2011 Andrew Johnson.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.0 or,
at your option, any later version of Perl 5 you may have available.

=head1 WARRANTY

This software comes with no warranty of any kind.

=cut

