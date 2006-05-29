# $Id$

chdir('t') if -d 't';
use lib qw(./lib ../lib);
use Test::More tests => 2;

use_ok('Proc::DaemonLite');
require_ok('Proc::DaemonLite');

1;

