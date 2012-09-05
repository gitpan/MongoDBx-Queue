use 5.010;
use strict;
use warnings;

package MongoDBx::Queue;

# ABSTRACT: A message queue implemented with MongoDB
our $VERSION = '0.002'; # VERSION

use Any::Moose;
use Const::Fast qw/const/;
use MongoDB 0.45 ();
use boolean;

const my $ID       => '_id';
const my $RESERVED => '_r';
const my $PRIORITY => '_p';


has db => (
  is       => 'ro',
  isa      => 'MongoDB::Database',
  required => 1,
);


has name => (
  is      => 'ro',
  isa     => 'Str',
  default => 'queue',
);


has safe => (
  is      => 'ro',
  isa     => 'Bool',
  default => 1,
);

# Internal collection attribute

has _coll => (
  is         => 'ro',
  isa        => 'MongoDB::Collection',
  lazy_build => 1,
);

sub _build__coll {
  my ($self) = @_;
  return $self->db->get_collection( $self->name );
}

# Methods


sub add_task {
  my ( $self, $data, $opts ) = @_;

  $self->_coll->insert(
    {
      %$data,
      $PRIORITY => $opts->{priority} // time(),
    },
    {
      safe => $self->safe,
    }
  );
}


sub reserve_task {
  my ( $self, $opts ) = @_;

  my $now    = time();
  my $result = $self->db->run_command(
    {
      findAndModify => $self->name,
      query         => {
        $PRIORITY => { '$lte' => $opts->{max_priority} // $now },
        $RESERVED => { '$exists' => boolean::false },
      },
      sort => { $PRIORITY => 1 },
      update => { '$set' => { $RESERVED => $now } },
    },
  );

  # XXX check get_last_error? -- xdg, 2012-08-29
  if ( ref $result ) {
    return $result->{value}; # could be undef if not found
  }
  else {
    die "MongoDB error: $result"; # XXX docs unclear, but imply string error
  }
}


sub reschedule_task {
  my ( $self, $task, $opts ) = @_;
  $self->_coll->update(
    { $ID => $task->{$ID} },
    {
      '$unset'  => { $RESERVED => 0 },
      '$set'    => { $PRIORITY => $opts->{priority} // $task->{$PRIORITY} },
    },
    { safe => $self->safe }
  );
}


sub remove_task {
  my ( $self, $task ) = @_;
  $self->_coll->remove( { $ID => $task->{$ID} } );
}


sub apply_timeout {
  my ( $self, $timeout ) = @_;
  $timeout //= 120;
  my $cutoff = time() - $timeout;
  $self->_coll->update(
    { $RESERVED => { '$lt'     => $cutoff } },
    { '$unset'  => { $RESERVED => 0 } },
    { safe => $self->safe, multiple => 1 }
  );
}


sub size {
  my ($self) = @_;
  return $self->_coll->count;
}


sub waiting {
  my ($self) = @_;
  return $self->_coll->count( { $RESERVED => { '$exists' => boolean::false } } );
}

no Any::Moose;
__PACKAGE__->meta->make_immutable;

1;


# vim: ts=2 sts=2 sw=2 et:

__END__

=pod

=head1 NAME

MongoDBx::Queue - A message queue implemented with MongoDB

=head1 VERSION

version 0.002

=head1 SYNOPSIS

  use v5.10;
  use MongoDB;
  use MongoDBx::Queue;

  my $connection = MongoDB::Connection->new( @parameters );
  my $database = $connection->get_database("queue_db");

  my $queue = MongoDBx::Queue->new( { db => $database } );

  $queue->add_task( { msg => "Hello World" } );
  $queue->add_task( { msg => "Goodbye World" } );

  while ( my $task = $queue->reserve_task ) {
    say $task->{msg};
    $queue->remove_task( $task );
  }

=head1 DESCRIPTION

B<ALPHA> -- this is an early release and is still in development.  Testing
and feedback welcome.

MongoDBx::Queue implements a simple, prioritized message queue using MongoDB as
a backend.  By default, messages are prioritized by insertion time, creating a
FIFO queue.

On a single host with MongoDB, it provides a zero-configuration message service
across local applications.  Alternatively, it can use a MongoDB database
cluster that provides replication and fail-over for an even more durable,
multi-host message queue.

Features:

=over 4

=item *

messages as hash references, not objects

=item *

arbitrary message fields

=item *

arbitrary scheduling on insertion

=item *

atomic message reservation

=item *

stalled reservations can be timed-out

=item *

task rescheduling

=back

Not yet implemented:

=over 4

=item *

parameter checking

=item *

error handling

=back

Warning: do not use with capped collections, as the queued messages will not
meet the constraints required by a capped collection.

=head1 ATTRIBUTES

=head2 db

A MongoDB::Database object to hold the queue.  Required.

=head2 name

A collection name for the queue.  Defaults to 'queue'.  The collection must
only be used by MongoDBx::Queue or unpredictable awful things will happen.

=head2 safe

Boolean that controls whether 'safe' inserts/updates are done.
Defaults to true.

=head1 METHODS

=head2 new

  $queue = MongoDBx::Queue->new( { db => $database, %options } );

Creates and returns a new queue object.  The C<db> argument is required.
Other attributes may be provided as well.

=head2 add_task

  $queue->add_task( \%message, \%options );

Adds a task to the queue.  The C<\%message> hash reference will be shallow
copied into the task and not include objects except as described by
L<MongoDB::DataTypes>.  Top-level keys must not start with underscores, which are
reserved for MongoDBx::Queue.

The C<\%options> hash reference is optional and may contain the following key:

=over 4

=item *

C<priority>: sets the priority for the task. Defaults to C<time()>.

=back

Note that setting a "future" priority may cause a task to be invisible
to C<reserve_task>.  See that method for more details.

=head2 reserve_task

  $task = $queue->reserve_task;
  $task = $queue->reserve_task( \%options );

Atomically marks and returns a task.  The task is marked in the queue as
"reserved" (in-progress) so it can not be reserved again unless is is
rescheduled or timed-out.  The task returned is a hash reference containing the
data added in C<add_task>, including private keys for use by MongoDBx::Queue
methods.

Tasks are returned in priority order from lowest to highest.  If multiple tasks
have identical, lowest priorities, their ordering is undefined.  If no tasks
are available or visible, it will return C<undef>.

The C<\%options> hash reference is optional and may contain the following key:

=over 4

=item *

C<max_priority>: sets the maximum priority for the task. Defaults to C<time()>.

=back

The C<max_priority> option controls whether "future" tasks are visible.  If
the lowest task priority is greater than the C<max_priority>, this method
returns C<undef>.

=head2 reschedule_task

  $queue->reschedule_task( $task );
  $queue->reschedule_task( $task, \%options );

Releases the reservation on a task so it can be reserved again.

The C<\%options> hash reference is optional and may contain the following key:

=over 4

=item *

C<priority>: sets the priority for the task. Defaults to the task's original priority.

=back

Note that setting a "future" priority may cause a task to be invisible
to C<reserve_task>.  See that method for more details.

=head2 remove_task

  $queue->remove_task( $task );

Removes a task from the queue (i.e. indicating the task has been processed).

=head2 apply_timeout

  $queue->apply_timeout( $seconds );

Removes reservations that occurred more than C<$seconds> ago.  If no
argument is given, the timeout defaults to 120 seconds.  The timeout
should be set longer than the expected task processing time, so that
only dead/hung tasks are returned to the active queue.

=head2 size

  $queue->size;

Returns the number of tasks in the queue, including in-progress ones.

=head2 waiting

  $queue->waiting;

Returns the number of tasks in the queue that have not been reserved.

=for :stopwords cpan testmatrix url annocpan anno bugtracker rt cpants kwalitee diff irc mailto metadata placeholders metacpan

=head1 SUPPORT

=head2 Bugs / Feature Requests

Please report any bugs or feature requests through the issue tracker
at L<https://github.com/dagolden/mongodbx-queue/issues>.
You will be notified automatically of any progress on your issue.

=head2 Source Code

This is open source software.  The code repository is available for
public review and contribution under the terms of the license.

L<https://github.com/dagolden/mongodbx-queue>

  git clone git://github.com/dagolden/mongodbx-queue.git

=head1 AUTHOR

David Golden <dagolden@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by David Golden.

This is free software, licensed under:

  The Apache License, Version 2.0, January 2004

=cut
