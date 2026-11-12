package CVSLogwatcher::DummyLogger;

# this logger does absolutely nothing at all; this is intended as the default
# logger unless something more useful is requested; the ability to not clutter
# the standard output with logs can be useful in unit tests

use v5.36;
use Moo;

sub info ($self, $msg, @args) {}
sub debug ($self, $msg, @args) {}
sub warn ($self, $msg, @args) {}
sub error ($self, $msg, @args) {}
sub fatal ($self, $msg, @args) {}
sub prefix ($self, $prefix) { $self }
sub level ($self, $level) {}

1;
