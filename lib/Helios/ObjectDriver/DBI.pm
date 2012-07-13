package Helios::ObjectDriver::DBI;

use 5.008;
use strict;
use warnings;
use base qw(Data::ObjectDriver::Driver::DBI);

our $VERSION = '2.50_2850';

my %Handles;
sub init_db {
    my $driver = shift;
    my $dbh;
    if ($driver->reuse_dbh) {
        $dbh = $Handles{$driver->dsn};
    }
    unless ($dbh) {
        eval {
            $dbh = DBI->connect_cached($driver->dsn, $driver->username, $driver->password,
                { RaiseError => 1, PrintError => 0, AutoCommit => 1, 'private_conn_'.$$ => $$,
                %{$driver->connect_options || {}} })
                or Carp::croak("Connection error: " . $DBI::errstr);
        };
        if ($@) {
            Carp::croak($@);
        }
    }
    if ($driver->reuse_dbh) {
        $Handles{$driver->dsn} = $dbh;
    }
    $driver->dbd->init_dbh($dbh);
    $driver->{__dbh_init_by_driver} = 1;
    return $dbh;
}

1;
__END__

=head1 NAME

Helios::ObjectDriver::DBI - Data::ObjectDriver subclass for Helios

=head1 DESCRIPTION

Helios::ObjectDriver::DBI is a Data::ObjectDriver::Driver::DBI subclass for 
Helios.  It overrides the init_db() method to implement aggressive DBI 
connection caching to greatly increase efficiency and performance.

The code in this module is lifted from Data::ObjectDriver::Driver::DBI and 
modified to use DBI->connect_cached() in a way that should be fork-safe.

=head1 LICENSE

I<Data::ObjectDriver> is free software; you may redistribute it and/or modify
it under the same terms as Perl itself.

=head1 MAILING LIST, CODE & MORE INFORMATION

I<Data::ObjectDriver> developers can be reached via the following group:
L<http://groups.google.com/group/data-objectdriver>

Bugs should be reported using the CPAN RT system, patches are encouraged when
reporting bugs.

L<http://code.sixapart.com/>

=head1 AUTHOR & COPYRIGHT

Except where otherwise noted, I<Data::ObjectDriver> is Copyright 2005-2006
Six Apart, cpan@sixapart.com. All rights reserved.

=cut