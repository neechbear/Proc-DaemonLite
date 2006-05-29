#!/home/nicolaw/webroot/perl-5.8.7/bin/perl -w

use strict;
use Proc::DaemonLite qw(:all);

my $pid = Proc::DaemonLite::init_server();
for my $cid (1..10) {
	my $child = launch_child();
	if ($child == 0) {
		warn "I am child PID $$" while sleep 1;
	} else {
		warn "Spawned child number $cid, PID $child";
	}
}

sleep 3;
kill_children();

