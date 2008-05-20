#!/usr/bin/perl

use strict;
use warnings;
use TheSchwartz;
use TheSchwartz::Job;
use Error qw(:try);

#use Data::Dumper;	#[]t

use Helios::Worker;

our $VERSION = '1.19_05';

=head1 NAME

helios_job_submit.pl - Submit a job to the Helios job processing system from the cmd line

=head1 SYNOPSIS

helios_job_submit.pl [--no-validate] I<jobclass> [I<jobargs>]

helios_job_submit.pl Index::IndexWorker "<params><id>699</id></params>"

helios_job_submit.pl --help

=head1 DESCRIPTION

Use helios_job_submit.pl to submit a job to the Helios job processing system from the cmd line.  
The first parameter is the job class, and the second is the parameter XML that will be passed to 
the worker class for the job.  If the second parameter isn't given, the program will accept input 
from STDIN; each line will be considered params for a separate job.

=cut

our $DEBUG_MODE = 0;
if (defined($ENV{HELIOS_DEBUG}) && $ENV{HELIOS_DEBUG} == 1) {
	$DEBUG_MODE = 1;
}

our $VALIDATE = 1;
if ( lc($ARGV[0]) eq '--no-validate') {
	shift @ARGV;
	$VALIDATE = 0;
}
our $JOB_CLASS = shift @ARGV;
our $PARAMS = shift @ARGV;

our $DATABASES_INFO;
our $VERBOSE = 0;

# print help if asked
if ( !defined($JOB_CLASS) || ($JOB_CLASS eq '--help') || ($JOB_CLASS eq '-h') ) {
	require Pod::Usage;
	Pod::Usage::pod2usage(-verbose => 2, -exitstatus => 0);
}

# instantiate the base worker class just to get the [global] INI params
# (we need to know where the Helios db is)
my $WORKER = new Helios::Worker;
$WORKER->getParamsFromIni();
my $params = $WORKER->getParams();

# if we were passed a <params> wodge of XML on the command line, 
# try to validate it, then add it to the $args array to be passed to TheSchwartz
# if we DIDN'T get a <params> wodge, 
# then we have to assume it's coming from STDIN.  
# We'll assume that each line coming in from STDIN is a separate <params> wodge, which will 
# ultimately mean there will be a job created for each line of input.

my $args;	# arrayref to feed to TheSchwartz
my $job;
my @jobs;
if ( defined($PARAMS) ) {
#[]old 	$args = [ $PARAMS ];
	# test the args before we submit
	if ($VALIDATE) { validateParamsXML($PARAMS) or exit(1); }
	$job = TheSchwartz::Job->new(
		funcname => $JOB_CLASS,
		arg      => [ $PARAMS ]
	);
	push(@jobs, $job);

} else {
	while (<>) {
		chomp;
		if ($VALIDATE) { validateParamsXML($_); }
		$job = TheSchwartz::Job->new(
			funcname => $JOB_CLASS,
			arg      => [ $_ ]
		);
		push(@jobs, $job);	}
}

$DATABASES_INFO = [
	{
		dsn => $params->{dsn},
		user => $params->{user},
		pass => $params->{password}
	}
];
												
my $client = TheSchwartz->new( databases => $DATABASES_INFO, verbose => 1 );
#[]? $client->set_verbose(1);

#[]old $client->insert($JOB_CLASS, $args);
my @handles = $client->insert_jobs(@jobs);
if ($DEBUG_MODE) {
	print scalar(@handles)," jobs submitted.  Job ids:\n";
	foreach (@handles) {
		print $_->jobid,"\n";
	}
}


=head1 SUBROUTINES

=head2 validateParamsXML($xml)

Given a wodge of parameter XML (wrapped by <params></params> tags), validateParamsXML returns 
a true value if the XML is valid, and a false value if it isn't.

=cut

sub validateParamsXML {
	my $arg = shift;
	try {
		my $arg = $WORKER->parseArgXML($arg);
		return 1;
	} catch Helios::Error::InvalidArg with {
		my $e = shift;
		print STDERR "Invalid job arguments: $arg (",$e->text(),")\n";
		return undef;
	};
}


=head1 SEE ALSO

L<TheSchwartz>

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

