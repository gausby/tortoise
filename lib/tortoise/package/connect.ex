defmodule Tortoise.Package.Connect do
  @moduledoc false

  @opcode 1

  # @allowed_properties [
  #   :authentication_data,
  #   :authentication_method,
  #   :maximum_packet_size,
  #   :receive_maximum,
  #   :request_problem_information,
  #   :request_response_information,
  #   :session_expiry_interval,
  #   :topic_alias_maximum,
  #   :user_property
  # ]

  alias Tortoise.Package

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            protocol: binary(),
            protocol_version: non_neg_integer(),
            user_name: binary() | nil,
            password: binary() | nil,
            clean_start: boolean(),
            keep_alive: non_neg_integer(),
            client_id: Tortoise.client_id(),
            will: Package.Publish.t() | nil,
            properties: [{any(), any()}]
          }

  defstruct __META__: %Package.Meta{opcode: @opcode},
            protocol: "MQTT",
            protocol_version: 0b00000101,
            user_name: nil,
            password: nil,
            clean_start: true,
            keep_alive: 60,
            client_id: nil,
            will: nil,
            properties: []

  @spec decode(binary()) :: t
  def decode(<<@opcode::4, 0::4, variable::binary>>) do
    <<
      4::big-integer-size(16),
      "MQTT",
      5::8,
      user_name::1,
      password::1,
      will_retain::1,
      will_qos::2,
      will::1,
      clean_start::1,
      0::1,
      keep_alive::big-integer-size(16),
      rest::binary
    >> = drop_length(variable)

    {properties, package} = Package.parse_variable_length(rest)
    properties = Package.Properties.decode(properties)

    payload =
      decode_payload(
        [
          client_id: true,
          will_properties: will == 1,
          will_topic: will == 1,
          will_payload: will == 1,
          user_name: user_name == 1,
          password: password == 1
        ],
        package
      )

    %__MODULE__{
      client_id: payload[:client_id],
      user_name: payload[:user_name],
      password: payload[:password],
      will:
        if will == 1 do
          %Package.Publish{
            topic: payload[:will_topic],
            payload: nullify(payload[:will_payload]),
            qos: will_qos,
            retain: will_retain == 1,
            properties: payload[:will_properties]
          }
          |> Package.Meta.infer()
        end,
      clean_start: clean_start == 1,
      keep_alive: keep_alive,
      properties: properties
    }
  end

  defp decode_payload([], <<>>) do
    []
  end

  defp decode_payload([{_ignored, false} | remaining_fields], payload) do
    decode_payload(remaining_fields, payload)
  end

  defp decode_payload(
         [{:will_properties, true} | remaining_fields],
         payload
       ) do
    {properties, rest} = Package.parse_variable_length(payload)
    value = Package.Properties.decode(properties)
    [{:will_properties, value}] ++ decode_payload(remaining_fields, rest)
  end

  defp decode_payload(
         [{field, true} | remaining_fields],
         <<length::big-integer-size(16), payload::binary>>
       ) do
    <<value::binary-size(length), rest::binary>> = payload
    [{field, value}] ++ decode_payload(remaining_fields, rest)
  end

  defp nullify(""), do: nil
  defp nullify(payload), do: payload

  defp drop_length(payload) do
    case payload do
      <<0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
    end
  end

  defimpl Tortoise.Encodable do
    def encode(%Package.Connect{client_id: client_id} = t, _opts)
        when is_binary(client_id) do
      [
        Package.Meta.encode(t.__META__),
        Package.variable_length_encode([
          protocol_header(t),
          connection_flags(t),
          keep_alive(t),
          Package.Properties.encode(t.properties),
          payload(t)
        ])
      ]
    end

    def encode(%Package.Connect{client_id: client_id} = t, opts)
        when is_atom(client_id) do
      encode(%Package.Connect{t | client_id: Atom.to_string(client_id)}, opts)
    end

    defp protocol_header(%{protocol: protocol, protocol_version: version}) do
      [Package.length_encode(protocol), version]
    end

    defp connection_flags(%{will: nil} = f) do
      <<
        flag(f.user_name)::integer-size(1),
        flag(f.password)::integer-size(1),
        # will retain
        flag(0)::integer-size(1),
        # will qos
        0::integer-size(2),
        # will flag
        flag(0)::integer-size(1),
        flag(f.clean_start)::integer-size(1),
        # reserved bit
        0::1
      >>
    end

    defp connection_flags(%{will: %Package.Publish{}} = f) do
      <<
        flag(f.user_name)::integer-size(1),
        flag(f.password)::integer-size(1),
        flag(f.will.retain)::integer-size(1),
        f.will.qos::integer-size(2),
        flag(f.will.topic)::integer-size(1),
        flag(f.clean_start)::integer-size(1),
        # reserved bit
        0::1
      >>
    end

    defp keep_alive(f) do
      <<f.keep_alive::big-integer-size(16)>>
    end

    defp payload(%{will: nil} = f) do
      [f.client_id, f.user_name, f.password]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&Package.length_encode/1)
    end

    defp payload(f) do
      options = [
        f.client_id,
        f.will.properties,
        f.will.topic,
        encode_payload(f.will.payload),
        f.user_name,
        f.password
      ]

      for data <- options,
          data != nil do
        case data do
          data when is_binary(data) ->
            Package.length_encode(data)

          data when is_list(data) ->
            Package.Properties.encode(data)
        end
      end
    end

    defp encode_payload(nil), do: ""
    defp encode_payload(payload), do: payload

    defp flag(f) when f in [0, nil, false], do: 0
    defp flag(_), do: 1
  end

  if Code.ensure_loaded?(StreamData) do
    defimpl Tortoise.Generatable do
      import StreamData

      alias Tortoise.Generatable.Topic

      def generate(%type{__META__: _meta} = package) do
        values = package |> Map.from_struct()

        fixed_list(Enum.map(values, &constant(&1)))
        |> bind(&gen_user_name/1)
        |> bind(&gen_password/1)
        |> bind(&gen_clean_start/1)
        |> bind(&gen_keep_alive/1)
        |> bind(&gen_client_id/1)
        |> bind(&gen_will/1)
        |> bind(&gen_properties/1)
        |> bind(fn data ->
          fixed_map([
            {:__struct__, type}
            | for({k, v} <- data, do: {k, constant(v)})
          ])
        end)
      end

      defp gen_clean_start(values) do
        case Keyword.pop(values, :clean_start) do
          {nil, values} ->
            fixed_list([
              {:clean_start, boolean()}
              | Enum.map(values, &constant(&1))
            ])

          {bool, _} when is_boolean(bool) ->
            constant(values)

          # User specified generators should produce a boolean
          {%StreamData{} = generator, values} ->
            bind(generator, fn
              bool when is_boolean(bool) ->
                fixed_list([
                  {:clean_start, bool}
                  | Enum.map(values, &constant(&1))
                ])

              _otherwise ->
                raise ArgumentError, "Clean start generator should produce a boolean"
            end)
        end
      end

      defp gen_keep_alive(values) do
        case Keyword.pop(values, :keep_alive) do
          {nil, values} ->
            fixed_list([
              {:keep_alive,
               frequency([
                 # Most of the time we will produce a reasonable keep
                 # alive value; somewhere between 1 and 5 minutes
                 {4, integer(60..300)},
                 # Sometimes produce a *very* long keep alive
                 # interval, the longest the MQTT spec support is a
                 # bit more than 18 hours!
                 {4, integer(301..0xFFFF)},
                 # Sometimes produce a value less than a minute
                 {1, integer(1..59)},
                 # A value of zero means that the client will not
                 # send ping requests on a particular schedule, and
                 # the server will not kick the client if it does
                 # not; this essentially turns the keep alive off
                 {1, constant(0)}
               ])}
              | Enum.map(values, &constant(&1))
            ])

          {value, _} when is_integer(value) and value in 0..0xFFFF ->
            constant(values)

          # User specified generators should produce an integer
          {%StreamData{} = generator, values} ->
            bind(generator, fn
              value when is_integer(value) and value in 0..0xFFFF ->
                fixed_list([
                  {:keep_alive, constant(value)}
                  | Enum.map(values, &constant(&1))
                ])

              _otherwise ->
                raise ArgumentError, """
                Keep alive generator should produce an integer between 0 and 65_535
                """
            end)
        end
      end

      defp gen_client_id(values) do
        case Keyword.pop(values, :client_id) do
          {nil, values} ->
            fixed_list([
              {:client_id,
               frequency([
                 # A server should accept a client id between 1 and 23
                 # chars in length consisting of 0-9, a-z, and A-Z.
                 {1, gen_client_id_string()},
                 # The server may accept a client id longer than 23
                 # chars, and of any chars
                 {1, string(:printable, min_length: 1)}
                 # If the client id is nil the server may assign a
                 # client id and send it as a property in the connack
                 # message
                 # {1, nil}
               ])}
              | Enum.map(values, &constant(&1))
            ])

          {%StreamData{} = generator, values} ->
            bind(generator, fn
              client_id when is_binary(client_id) or is_nil(client_id) ->
                fixed_list([
                  {:client_id, constant(client_id)}
                  | Enum.map(values, &constant(&1))
                ])

              _otherwise ->
                raise ArgumentError, "A client id should be nil or a binary"
            end)

          {<<_::binary>>, _} ->
            constant(values)
        end
      end

      defp gen_client_id_string() do
        list_of(
          one_of([integer(?A..?Z), integer(?a..?z), integer(?0..?9)]),
          min_length: 1,
          max_length: 23
        )
        |> bind(&constant(List.to_string(&1)))
      end

      defp gen_user_name(values) do
        case Keyword.pop(values, :user_name) do
          {nil, values} ->
            fixed_list([
              {:user_name, one_of([nil, string(:printable)])}
              | Enum.map(values, &constant(&1))
            ])

          {%StreamData{} = generator, values} ->
            bind(generator, fn
              user_name when is_binary(user_name) or is_nil(user_name) ->
                fixed_list([
                  {:user_name, constant(user_name)}
                  | Enum.map(values, &constant(&1))
                ])

              _otherwise ->
                raise ArgumentError, "User name should be nil or a binary"
            end)

          {<<_::binary>>, _} ->
            constant(values)
        end
      end

      defp gen_password(values) do
        case Keyword.pop(values, :password) do
          {nil, values} ->
            fixed_list([
              {:password, one_of([nil, binary()])}
              | Enum.map(values, &constant(&1))
            ])

          {%StreamData{} = generator, values} ->
            bind(generator, fn
              password when is_binary(password) or is_nil(password) ->
                fixed_list([
                  {:password, constant(password)}
                  | Enum.map(values, &constant(&1))
                ])

              _otherwise ->
                raise ArgumentError, "Password should be nil or a binary"
            end)

          {<<_::binary>>, _} ->
            constant(values)
        end
      end

      defp gen_will(values) do
        case Keyword.pop(values, :will) do
          {nil, values} ->
            fixed_list([
              {:will,
               Package.generate(%Package.Publish{
                 identifier: constant(nil),
                 dup: false,
                 retain: nil,
                 qos: nil,
                 properties: gen_will_properties()
               })}
              | Enum.map(values, &constant(&1))
            ])

          {%Package.Publish{}, _values} ->
            constant(values)
        end
      end

      defp gen_will_properties() do
        uniq_list_of(
          # Use frequency to make it more likely to pick a user
          # property as we are allowed to have multiple of them;
          # the remaining properties may only occur once,
          # without the weights we could end up in situations
          # where StreamData gives up because it cannot find any
          # candidates that hasn't been chosen before
          frequency([
            # here we allow stings with a byte size of zero; don't
            # know if that is a problem according to the spec. Let's
            # handle that situation just in case:
            {6, {:user_property, {string(:printable), string(:printable)}}},
            {1, {:will_delay_interval, integer(0..0xFFFFFFFF)}},
            {1, {:payload_format_indicator, integer(0..1)}},
            {1, {:message_expiry_interval, integer(0..0xFFFFFFFF)}},
            {1, {:content_type, string(:printable)}},
            {1, {:response_topic, bind(Topic.gen_topic(), &constant(Enum.join(&1, "/")))}},
            {1, {:correlation_data, binary()}}
          ]),
          uniq_fun: &uniq/1,
          max_length: 10
        )
      end

      defp gen_properties(values) do
        case Keyword.pop(values, :properties) do
          {nil, values} ->
            properties =
              uniq_list_of(
                # Use frequency to make it more likely to pick a user
                # property as we are allowed to have multiple of them;
                # the remaining properties may only occur once,
                # without the weights we could end up in situations
                # where StreamData gives up because it cannot find any
                # candidates that hasn't been chosen before
                frequency([
                  # here we allow stings with a byte size of zero; don't
                  # know if that is a problem according to the spec. Let's
                  # handle that situation just in case:
                  {8, {:user_property, {string(:printable), string(:printable)}}},
                  {1, {:maximum_packet_size, integer(1..0xFFFFFFFF)}},
                  {1, {:receive_maximum, integer(1..0xFFFF)}},
                  {1, {:request_problem_information, boolean()}},
                  {1, {:request_response_information, boolean()}},
                  {1, {:session_expiry_interval, integer(0..0xFFFFFFFF)}},
                  {1, {:topic_alias_maximum, integer(0..0xFFFF)}},
                  {1, {:authentication_method, string(:printable)}}
                ]),
                uniq_fun: &uniq/1,
                max_length: 10
              )
              |> bind(fn properties ->
                if Keyword.has_key?(properties, :authentication_method) do
                  one_of([
                    constant(properties),
                    fixed_list([
                      {:authentication_data, binary()}
                      | Enum.map(properties, &constant(&1))
                    ])
                  ])
                else
                  constant(properties)
                end
              end)

            fixed_list([
              {constant(:properties), properties}
              | Enum.map(values, &constant(&1))
            ])

          {_passthrough, _} ->
            constant(values)
        end
      end

      defp uniq({:user_property, _v}), do: :crypto.strong_rand_bytes(2)
      defp uniq({k, _v}), do: k
    end
  end
end
