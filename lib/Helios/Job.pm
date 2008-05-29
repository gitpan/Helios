package Helios::Job;

use 5.008000;
use base qw( TheSchwartz::Job );
use strict;
use warnings;

use Config::IniFiles;
use DBI;
use Error qw(:try);
require XML::Simple;
$XML::Simple::PREFERRED_PARSER = 'XML::Parser';

use Helios::Error;

our $VERSION = '1.19_07';


=head1 NAME

Helios::Job - base class for workers in the Helios job processing system

=head1 DESCRIPTION

Helios::Job extends TheSchwartz::Job class with methods to handle the proper Helios functions.

Right now, it is just a wrapper around TheSchwartz::Job.  Soon, job parameter and control methods
from Helios::Worker will be moved here.

=cut


1;
__END__


=head1 SEE ALSO

L<Helios::Worker>, L<TheSchwartz::Job>, L<XML::Simple>, L<Config::IniFiles>

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

