package Helios;

use 5.008000;

our $VERSION = '1.19_07';


=head1 NAME

Helios - a framework for developing asynchronous distributed job processing applications

=head1 DESCRIPTION

Helios is a system for building asynchronous distributed job processing applications.  
Applications that need to process millions of small units of work in parallel can use the Helios 
system to scale this work across the multiple processes and servers that form a Helios collective. 
Helios may also be used to improve the user experience on websites.  By utilizing the framework's 
asynchronous job processing services, potential timeout issues can be eliminated and response times 
decreased for larger tasks invoked in response to user input.  The web server application can "fire 
and forget" in the background, immediately returning control to the user.  Using Helios, simple 
Perl applications can be written to distribute workloads throughout the Helios collective while 
still retaining centralized management.

The Helios module itself is merely a placeholder for versioning and documentation purposes.  If 
you want to require Helios (or a certain version of it) in your package, adding 

 Helios => 1.19

to the PREREQ_PM hashref in Makefile.PL should do the trick.

There will be more documentation here soon, about Helios system concepts, worker class creation, 
etc.


=head1 SEE ALSO

L<helios.pl>, L<Helios::Worker>, L<Helios::Error>

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
