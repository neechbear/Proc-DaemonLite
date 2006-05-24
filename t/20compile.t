# $Id: 20compile.t 459 2006-05-19 19:26:42Z nicolaw $

chdir('t') if -d 't';
use lib qw(./lib ../lib);
use Test::More tests => 2;

use_ok('Proc::DaemonLite');
require_ok('Proc::DaemonLite');

1;

