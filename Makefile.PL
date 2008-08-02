use 5.008000;
use ExtUtils::MakeMaker;

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# # the contents of the Makefile that is written.
WriteMakefile(
    NAME              => 'Helios',
    AUTHOR            => 'Andrew Johnson <ajohnson at ittoolbox dotcom>',
    ABSTRACT          => 'A framework for developing asynchronous distributed job processing applications.',
    LICENSE           => 'perl',
    VERSION_FROM      => 'lib/Helios.pm', # finds $VERSION
    PREREQ_PM         => {   Test::Simple           => 0.72,
                             Data::ObjectDriver     => 0.04,
                             DBI                    => 1.60,
                             TheSchwartz            => 1.04,
                             Config::IniFiles       => 2.38,
                             DBD::mysql             => 3.0,
                             Error                  => 0.17,
                             XML::Parser            => '',
                             XML::NamespaceSupport  => 1.04,
                             XML::SAX               => '',
                             XML::Simple            => 2.18,
                             Sys::Syslog            => 0.23,
                             Sys::Hostname          => 1.00,
                             Bundle::LWP            => '',
                             Pod::Usage             => ''
							},
    EXE_FILES         => [ 'helios.pl', 'helios_job_submit.pl', 'helios_log_clean.pl'],
    INST_SCRIPT       => 'bin',
);


