############################################################
#
#   $Id$
#   Proc::DaemonLite - Simple server daemonisation module
#
#   Copyright 2006 Nicola Worthington
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
############################################################

package Daemon;
# vim:ts=4:sw=4:tw=78

use strict;
use Exporter;
use Carp qw(croak cluck carp);
use POSIX qw(:signal_h setsid WNOHANG);
#use Carp::Heavy; # Is this really needed?
use File::Basename qw(basename);
use IO::File;
use Cwd qw(getcwd);
use Sys::Syslog qw(:DEFAULT setlogsock);

use constant PIDPATH  => -d '/var/run' ? '/var/run' : '/var/tmp';
use constant FACILITY => 'local0';

use vars qw($VERSION $DEBUG @EXPORT @EXPORT_OK %EXPORT_TAGS @ISA %CHILDREN);

$VERSION = '0.00_1' || sprintf('%d', q$Revision$ =~ /(\d+)/g);
$DEBUG = $ENV{DEBUG} ? 1 : 0;

@ISA = qw(Exporter);
@EXPORT_OK = qw(&init_server &prepare_child &kill_children &launch_child
		&do_relaunch &log_debug &log_notice &log_warn &log_die %CHILDREN);
@EXPORT = qw(&init_server);
%EXPORT_TAGS = (all => \@EXPORT_OK);

# These are private
my ($pid, $pidfile, $saved_dir, $CWD);

sub init_server {
	my ($user, $group);
	($pidfile, $user, $group) = @_;
	$pidfile ||= getpidfilename();
	my $fh = open_pid_file($pidfile);
	become_daemon();
	print $fh $$;
	close $fh;
	init_log();
	change_privileges($user, $group) if defined $user && defined $group;
	return $pid = $$;
}

sub become_daemon {
	croak "Can't fork" unless defined(my $child = fork);
	exit(0) if $child;   # parent dies;
	POSIX::setsid();     # become session leader
	open(STDIN,  "</dev/null");
	open(STDOUT, ">/dev/null");
	open(STDERR, ">&STDOUT");
	$CWD = Cwd::getcwd;  # remember working directory
	chdir '/';           # change working directory
	umask(0);            # forget file mode creation mask
	$ENV{PATH} = '/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin';
	delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};
	$SIG{CHLD} = \&reap_child;
}

sub change_privileges {
	my ($user, $group) = @_;
	my $uid = getpwnam($user)  or die "Can't get uid for $user\n";
	my $gid = getgrnam($group) or die "Can't get gid for $group\n";
	$) = "$gid $gid";
	$( = $gid;
	$> = $uid;           # change the effective UID (but not the real UID)
}

sub launch_child {
	my $callback = shift;
	my $home     = shift;
	my $signals  = POSIX::SigSet->new(SIGINT, SIGCHLD, SIGTERM, SIGHUP);
	sigprocmask(SIG_BLOCK, $signals);    # block inconvenient signals
	log_die("Can't fork: $!") unless defined(my $child = fork());
	if ($child) {
		$CHILDREN{$child} = $callback || 1;
	} else {
		$SIG{HUP} = $SIG{INT} = $SIG{CHLD} = $SIG{TERM} = 'DEFAULT';
		prepare_child($home);
	}
	sigprocmask(SIG_UNBLOCK, $signals);    # unblock signals
	return $child;
}

sub prepare_child {
	my $home = shift;
	if ($home) {
		local ($>, $<) = ($<, $>);         # become root again (briefly)
		chdir($home)  || croak "chdir(): $!";
		chroot($home) || croak "chroot(): $!";
	}
	$< = $>;                               # set real UID to effective UID
}

sub reap_child {
	while ((my $child = waitpid(-1, WNOHANG)) > 0) {
		$CHILDREN{$child}->($child) if ref $CHILDREN{$child} eq 'CODE';
		delete $CHILDREN{$child};
	}
}

sub kill_children {
	kill TERM => keys %CHILDREN;

	# wait until all the children die
	sleep while %CHILDREN;
}

sub do_relaunch {
	$> = $<;    # regain privileges
	chdir $1 if $CWD =~ m!([./a-zA-z0-9_-]+)!;
	croak "bad program name" unless $0 =~ m!([./a-zA-z0-9_-]+)!;
	my $program = $1;
	my $port = $1 if $ARGV[0] =~ /(\d+)/;
	unlink($pidfile);
	exec('perl', '-T', $program, $port) or croak "Couldn't exec: $!";
}

sub init_log {
	Sys::Syslog::setlogsock('unix');
	my $basename = File::Basename::basename($0);
	openlog($basename, 'pid', FACILITY);
	$SIG{__WARN__} = \&log_warn;
	$SIG{__DIE__}  = \&log_die;
}

sub log_debug  { syslog('debug',   _msg(@_)) }
sub log_notice { syslog('notice',  _msg(@_)) }
sub log_warn   { syslog('warning', _msg(@_)) }

sub log_die {
	Sys::Syslog::syslog('crit', _msg(@_)) unless $^S;
	die @_;
}

sub _msg {
	my $msg = join('', @_) || "Something's wrong";
	my ($pack, $filename, $line) = caller(1);
	$msg .= " at $filename line $line\n" unless $msg =~ /\n$/;
	$msg;
}

sub getpidfilename {
	my $basename = File::Basename::basename($0, '.pl');
	return PIDPATH . "/$basename.pid";
}

sub open_pid_file {
	my $file = shift;
	if (-e $file) {    # oops.  pid file already exists
		my $fh = IO::File->new($file) || return;
		my $pid = <$fh>;
		croak "Invalid PID file" unless $pid =~ /^(\d+)$/;
		croak "Server already running with PID $1" if kill 0 => $1;
		cluck "Removing PID file for defunct server process $pid.\n";
		croak "Can't unlink PID file $file" unless -w $file && unlink $file;
	}
	return IO::File->new($file, O_WRONLY | O_CREAT | O_EXCL, 0644)
		or die "Can't create $file: $!\n";
}

END {
	$> = $<;    # regain privileges
	unlink $pidfile if defined $pid and $$ == $pid;
}

sub TRACE {
	return unless $DEBUG;
	warn(shift());
}

sub DUMP {
	return unless $DEBUG;
	eval {
		require Data::Dumper;
		warn(shift().': '.Data::Dumper::Dumper(shift()));
	}
}

1;

=pod

=head1 NAME

Proc::DaemonLite - Simple server daemonisation module

=head1 SYNOPSIS

 use strict;
 use Proc::DaemonLite qw(:all);
 
 my $pid = init_server();
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

=head1 DESCRIPTION

Proc::DaemonLite is a basic server daemonisation module that trys
to cater for most basic Perl daemon requirements.

The POD for this module is incomplete, as is some of the tidying
of the code. It is however fully functional. This is a pre-release
in order to reserve the namespace before it becomes unavailable.

=head1 EXPORTS

By default only I<init_server()> is exported. The export tag I<all> will export
the following: I<init_server()>, I<prepare_child()>, I<kill_children()>,
I<launch_child()>, I<do_relaunch()>, I<log_debug()>, I<log_notice()>,
I<log_warn()>, I<log_die()> and I<%CHILDREN>.

=head2 init_server()

 my $pid = init_server($pidfile, $user, $group);

=head2 prepare_child()

 prepare_child($home);

=head2 launch_child()

 my $child_pid = prepare_child($callback, $home);

=head2 kill_children()

 kill_children();

Terminate all children with a I<TERM> signal.

=head2 do_relaunch()

 do_relaunch()

Attempt to start a new incovation of the current script.

=head2 log_debug()

 log_debug(@messages);

=head2 log_notice()

 log_notice(@messages);

=head2 log_warn()

 log_warn(@messages);

=head2 log_die()

 log_die(@messages);

=head2 %CHILDREN

I<%CHILDREN> is a hash of all child processes keyed by PID. Children
with registered callbacks will contain a reference to their callback
in this hash.

=head1 SEE ALSO

L<Proc::Deamon>, L<Proc::Fork>, L<Proc::Application::Daemon>,
L<Proc::Forking>, L<Proc::Background>, L<Net::Daemon>,
L<POE::Component::Daemon>, L<http://www.modperl.com/perl_networking/>,
L<perlfork>

=head1 VERSION

$Id$

=head1 AUTHOR

Nicola Worthington <nicolaw@cpan.org>

L<http://perlgirl.org.uk>

Original code written by Lincoln D. Stein, featured in "Network Programming
with Perl". L<http://www.modperl.com/perl_networking/>

Released with permission of Lincoln D. Stein.

=head1 COPYRIGHT

Copyright 2006 Nicola Worthington.

This software is licensed under The Apache Software License, Version 2.0.

L<http://www.apache.org/licenses/LICENSE-2.0>

=cut


__END__



