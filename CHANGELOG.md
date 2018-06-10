# Changelog

## 0.3.0 - 2018-06-10

### Added

- Thanks to [Troels Brødsgaard](https://github.com/trarbr) Tortoise
  now implement a module for its registry. This is found in
  `Tortoise.Registry`.

- The user defined controller handler callback module now accept "next
  actions" in the return tuple; this allow the user to specify that a
  topic should get subscribed to, or unsubscribed from, by specifying
  a return like `{:ok, new_state, [{:subscribe, "foo/bar", qos: 3},
  {:unsubscribe, "baz/quux"}]`.

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
