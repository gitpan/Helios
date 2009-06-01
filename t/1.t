# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl Helios.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use Test::More tests => 4;
BEGIN { 
	use_ok('Helios::Service');
	# check the exception framework
	use_ok('Helios::Error::Warning');
	use_ok('Helios::Error::Fatal');
	use_ok('Helios::Error::FatalNoRetry');
};

#########################
