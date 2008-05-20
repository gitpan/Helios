package Helios::Error::DatabaseError;

use base qw(Error::Simple);

our $VERSION = '1.20';

1;
__END__;

=head1 NAME

Helios::Error::DatabaseError - exception class for Helios job processing system to denote a 
database error occurred

=head1 SYNOPSIS

 use Helios::Error::DatabaseError;
 -OR-
 use Helios::Error;    # automatically uses DatabaseError and other exceptions

 =head1 DESCRIPTION

When Helios utility methods encounter a database error interacting with the Helios database, 
they will throw a DatabaseError exception.

This exception class was added to help helios.pl deal with losing its database connection (due to 
intermittent network error, database error, sunspots, whatever).  

=head1 SEE ALSO

L<Helios::Error::FatalNoRetry>, L<Helios::Error::Warning>, L<Error>, L<Error::Simple>

=head1 AUTHOR

Andrew Johnson, E<lt>ajohnson@ittoolbox.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2007-8 by CEB Toolbox, Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.0 or,
at your option, any later version of Perl 5 you may have available.

=head1 WARRANTY

This software comes with no warranty of any kind.

=cut

