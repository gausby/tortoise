# Changelog

## 0.9.3 - 2018-11-15

### Fixed

- Pass on connection errors so we can back-off on connection timeouts.

## 0.9.2 - 2018-09-01

### Added

- A use-macro has been added to `Tortoise.Handler` which implements
  default behaviour for the callbacks so the user only have to
  implement the callbacks they care about. This should improve
  usability of the project quite a bit.

## 0.9.1 - 2018-08-31

### Fixed

- Avoid a possible race condition that could happen when a connection
  was requested while the connection was in the process of being
  established. This update should avoid hanging processes when a
  publish is attempted in the small window between going from
  connecting to connected.

### Added

- A usage example was added to the README-file. Thanks, [Tanweer
  Shahzaad](https://github.com/tanweerdev).

## 0.9.0 - 2018-08-29

### Changed

- The `Tortoise` module does no longer delegate the `subscribe`,
  `unsubscribe`, and their `_sync` variants to the
  `Tortoise.Connection` module. They should just be accessed directly
  on the `Tortoise.Connection` module instead. This is done to make
  the documentation efforts easier, because conceptually the
  subscription belongs to the connection.

### Fixed

- Improvements has been made to the type specs and the documentation
  of various modules.

### Added

- A `ping/1` and `ping_sync/2` function has been added to the
  `Tortoise.Connection` module. This allow the user to ping the broker
  to check the connection. Notice that the connection process will
  still send ping messages to fulfill the connection keep alive
  timeout interval. There is no need to manually ping an open
  connection.

## 0.8.3 - 2018-08-28

### Fixed

- Upgraded to a more recent version of dialyxir and made the project
  pass the dialyzer.

## 0.8.2 - 2018-08-26

### Fixed

- As according to the specification, an unsubscribe, and a subscribe
  package can no longer be encoded if it has no topic filters defined.

- Got rid of TravisCI in favor of SemaphoreCI. Hopefully this will
  provide more reliable CI, and a funner experience for people working
  on Tortoise.

## 0.8.1 - 2018-08-25

### Added

- `disconnect/1` has been added to the `Tortoise.Connection`
  module. Given a `client_id` it will close down the connection
  cleanly; in flight messages will get canceled and a disconnect
  package will be send to the broker.

## 0.8.0 - 2018-08-19

### Changed

- When a connection drop the inflight manager will now re-transmit
  packages with quality of service that was inflight when the regain a
  connection.

- Improved the logic for handling incoming publishes with Quality of
  Service 2 (exactly once delivery). The inflight manager will ensure
  we only handle the message once (as we should); possible duplicate
  messages caused by retransmisions should get trapped and not
  forwarded to the user defined publish handler.

- It is now possible to pass in a binary/string as the host for a
  connection using the `Tortoise.Transport.SSL` module; it will be
  coerced to a charlist.

### Added

- The documentation on how to connect to a broker using the
  `Tortoise.Transport.SSL` method has been improved by [Bram
  Verburg](https://github.com/voltone).

## 0.7.0 - 2018-08-09

### Changed

- The controller will stop with an `{:protocol_violation,
  {:unexpected_package_from_remote, package}}` if the server send a
  package of the type `package`. This is the right thing to do because
  servers should implement the protocol proper, and clients should not
  accept unexpected packages.

- Instead of using the Logger module to log the ping response times
  from the connection keep alive messages the ping response times are
  not dispatched using a the ETS based PubSub. This will allow the
  user to log, or do whatever they want with the ping response time.

- Expose connection status changes via the `Tortoise.Events` pubsub
  making it possible to implement custom behavior when the connection
  goes down and when it becomes available. Great for setting up
  alarms.

- The receiver will now broadcast a "status down" message on the
  `Tortoise.Events` pubsub, and the connection process will listen for
  that message and enter the reconnect on status change.

### Removed

- `Tortoise.Connection.reconnect/1` has been removed as it is has been
  replaced with the pubsub based status-down message approach
  described in the "changed"-section. It might make a return at some
  point, but for now it has been removed.

## 0.6.0 - 2018-07-29

### Changed

- Keep the active connection in a ETS based registry, allowing
  processes that publish messages to the wire, using either
  `Tortoise.publish/4` or `Tortoise.Pipe.publish/4` to obtain the
  network connection and shoot the message directly on the network
  socket. With this change we can also error out if a process tries to
  send on a non-existing connection.

- The implementation for `Tortoise.publish/4` and
  `Tortoise.publish_sync/4` has been moved to the `Tortoise` module
  itself and is therefore no longer delegated to the
  `Tortoise.Connection` module. This changes the interface a bit but
  makes for a cleaner interface.

### Added

- This release introduces a `Tortoise.Events` module that implements a
  `Registry` based PubSub. Tortoise will use this to dispatch system
  events to listeners. For now it is used to dispatch new network
  connections, which is currently used by `Tortoise.publish`, the
  `Tortoise.Connection.Inflight` process, and the `Tortoise.Pipe`s. In
  the future we might add more message types to `Tortoise.Events`.

- Tests for `Tortoise.publish/4` and `Tortoise.publish_sync/4`

### Removed

- The `Tortoise.Connection.Transmitter` process is no longer needed,
  so it has been removed.

- Some dead code in the `Tortoise.Connection.Inflight` module has been
  removed. This should not change anything user facing.

### Fixed

- A server sending a ping request to a client is now considered a
  protocol violation, as specified by both the MQTT 3.1.1 and MQTT 5
  specifications.

- The connection process will now cancel the keep alive timer if it
  goes offline. Previously it would terminate itself because it would
  not get the ping response from the server.

- Regression: The receiver will no longer crash on an assertion when
  it request a reconnect from the `Tortoise.Connection` process.

- The specified Elixir version in the mix.exs file should now allow
  more versions of Elixir without warnings.

## 0.5.1 - 2018-07-23

### Fixed

- The receiver could report an invalid header length protocol
  violation when the server send too few bytes, and thus taking too
  long sending the complete package header. This patch will ensure we
  only report invalid header length when we have pulled more than 40
  bits in.

## 0.5.0 - 2018-07-18

### Added

- Documentation. Lot's of documentation. It might be a bit wordy, and
  it might repeat itself here and there, but it is a start that can be
  improved upon and good enough for a 0.4.4 release.

- Added some articles that describe usage of Tortoise and MQTT.

### Changed

- rename `renew/1` to `reconnect/1` on `Tortoise.Connection`-module.

- Some type specs has been altered to better fit reality.

- The `Tortoise.Transport.Tcp` transport will now accept a binary as a
  host name. Internally it will cast it to a char list.

## 0.4.3 - 2018-07-17

### Changed

- The wrong field was pulled out of the configuration options when the
  last will message was set, so it was impossible to configure a last
  will message. The last will message can now be set by passing in a
  `%Tortoise.Package.Publish{}` struct as the `:will` when starting a
  connection.

## 0.4.2 - 2018-07-08

### Changed

- The `Tortoise.Connection.renew/1` will now return `:ok` on success;
  allowing the `Torotise.Connection.Receiver` to not crash on its
  assertion when it request a reconnect.

## 0.4.1 - 2018-07-08

### Changed

- Tortoise should now survive the server it is connected to being
  restarted. `{:error, :econnrefused}` and `{:error, :closed}` has
  been added to the errors that make tortoise attempt a reconnect.

## 0.4.0 - 2018-07-08

### Added

- Incremental backoff has been added to the connector, allowing us to
  retry reconnecting to the broker if the initial (or later reconnect)
  attempt fails. The backoff will per default start retrying after 100
  ms and it will increment in multiples of 2 up until 30 seconds, at
  which point it will flip back to 100 ms and start over. This should
  ensure that we will be able to connect fairly quickly if it is a
  network fluke (or the network devise is not ready yet), and still
  not try *too often* or *too quickly*.

  The backoff can be configured by passing `backoff` containing a
  keyword list to the connection specification. Example `backoff:
  [min_interval: 100, max_interval: 30_000]`. Both times are in
  milliseconds.

### Changed

- The code for establishing a connection and eventually reconnecting
  has been combined into one. This makes it easier to test and verify,
  and it will make it easier to handle connection errors.

  Because the initial connection is happening outside of the `init/1`
  function the possible return values of the
  `Tortoise.Connection.start_link/1`-function has changed a bit. A
  fatal error will cause the connection process to exit instead
  because the init will always return `{:ok, state}`. This might break
  some implementation using Tortoise.

  For now it is only `{:error, :nxdomain}` that is handled with
  connection retries. Error categorization has been planned so we can
  error out if it is a non-recoverable error reason (such as no cacert
  files specified), instead of retrying the connection. In the near
  future more error reasons will be handled with reconnect attempts.

- A protocol violation from the server during connection will be
  handled better; previously it would error with a decoding error,
  because it would attempt to decode 4 random bytes. The error message
  should be obvious now.

## 0.3.0 - 2018-06-10

### Added

- Thanks to [Troels Brødsgaard](https://github.com/trarbr) Tortoise
  now implement a module for its registry. This is found in
  `Tortoise.Registry`.

- The user defined controller handler callback module now accept "next
  actions" in the return tuple; this allow the user to specify that a
  topic should get subscribed to, or unsubscribed from, by specifying
  a return like `{:ok, new_state, [{:subscribe, "foo/bar", qos: 3},
  {:unsubscribe, "baz/quux"}]}`.

  This is needed as the controller must not be blocked, and the user
  defined callback module run in the context of the controller. By
  allowing next actions like this the user can subscribe and
  unsubscribe to topics when certain events happen.

- The test coverage tool will now ignore modules found in the
  *lib/tortoise/handlers/*-folder. These modules implement the
  `Tortoise.Handler`-behaviour, so they should be good.

### Changed

- `Tortoise.subscribe/3` is now async, so a message will get sent to
  the mailbox of the calling process. The old behavior can be found in
  the newly created `Tortoise.subscribe_sync/3` that will block until
  the server has acknowledged the subscribe.

- `Tortoise.unsubscribe/3` is now also async, so like the subscribe a
  message will get sent to the mailbox of the calling process. The old
  behavior can be found in the newly added
  `Tortoise.unsubscribe_sync/3` that will block until the server has
  acknowledged the subscribe.

- A major refactorization of the code handling the logic running the
  user defined controller callbacks has been lifted from the
  `Tortoise.Connection.Controller` and put into the `Tortoise.Handler`
  module. This change made it possible to support the next actions,
  and makes it much easier test and add new next action types in the
  future.

## 0.2.2 - 2018-05-29

### Changed

- Fix an issue where larger messages would crash the receiver. It has
  been fixed and tested with messages as large as 268435455 bytes;
  which is a pretty big MQTT message.

## 0.2.1 - 2018-05-29

### Added

- The `Tortoise.Transport.SSL` will now pass in `[verify:
  :verify_peer]` as the default option when connecting. This will
  guide the user to pass in a list of trusted CA certificates, such as
  one provided by the Certifi package, or opt out of this by passing
  the `verify: :verify_none` option; this will make it hard for the
  user to make unsafe choices.

  Thanks to [Bram Verburg](https://github.com/voltone) for this
  improvement.

## 0.2.0 - 2018-05-28

### Added

- Experimental SSL support, please try it out and provide feedback.

- Abstract the network communication into a behaviour called
  `Tortoise.Transport`. This behaviour specify callbacks needed to
  connect, receive, and send messages using a network transport. It
  also specify setting and getting options, as well as listening using
  that network transport; the latter part is done so they can be used
  in integration tests.

- A TCP transport has been created for communicating with a broker
  using TCP. Use `Tortoise.Transport.Tcp` when specifying the server
  in the connection to use the TCP transport.

- A SSL transport `Tortoise.Transport.SSL` has been added to the
  project allowing us to connect to a broker using an encrypted
  connection.

### Removed

- The `{:tcp, 'localhost', 1883}` connection specification has been
  removed in favor of `{Tortoise.Transport.Tcp, host: 'localhost',
  port: 1883}`. This is done because we support multiple transport
  types now, such as the `Tortoise.Transport.SSL` type (which also
  takes a `key` and a `cert` option). The format is `{transport,
  opts}`.

## 0.1.0 - 2018-05-21

### Added
- The project is now on Hex which will hopefully broaden the user
  base. Future changes will be logged to this file.

- We will from now on update the version number following Semantic
  Versioning, and major changes should get logged to this file.
