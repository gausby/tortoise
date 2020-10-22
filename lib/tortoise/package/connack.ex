defmodule Tortoise.Package.Connack do
  @moduledoc false

  @opcode 2

  # @allowed_properties [:assigned_client_identifier, :authentication_data, :authentication_method, :maximum_packet_size, :maximum_qos, :reason_string, :receive_maximum, :response_information, :retain_available, :server_keep_alive, :server_reference, :session_expiry_interval, :shared_subscription_available, :subscription_identifier_available, :topic_alias_maximum, :user_property, :wildcard_subscription_available]

  alias Tortoise.Package

  @type reason :: :success | {:refused, refusal_reasons()}
  @type refusal_reasons ::
          :unspecified_error
          | :malformed_packet
          | :protocol_error
          | :implementation_specific_error
          | :unsupported_protocol_version
          | :client_identifier_not_valid
          | :bad_user_name_or_password
          | :not_authorized
          | :server_unavailable
          | :server_busy
          | :banned
          | :bad_authentication_method
          | :topic_name_invalid
          | :packet_too_large
          | :quota_exceeded
          | :payload_format_invalid
          | :retain_not_supported
          | :qos_not_supported
          | :use_another_server
          | :server_moved
          | :connection_rate_exceeded

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            session_present: boolean(),
            reason: reason(),
            properties: [{any(), any()}]
          }
  @enforce_keys [:reason]
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0},
            session_present: false,
            reason: :success,
            properties: []

  @spec decode(binary(), opts :: Keyword.t()) :: t
  def decode(<<@opcode::4, 0::4, variable_header::binary>>, _opts) do
    <<0::7, session_present::1, reason_code::8, properties::binary>> =
      Package.drop_length_prefix(variable_header)

    %__MODULE__{
      session_present: session_present == 1,
      reason: coerce_reason_code(reason_code),
      properties: Package.Properties.decode(properties)
    }
  end

  defp coerce_reason_code(reason_code) do
    case reason_code do
      0x00 -> :success
      0x80 -> {:refused, :unspecified_error}
      0x81 -> {:refused, :malformed_packet}
      0x82 -> {:refused, :protocol_error}
      0x83 -> {:refused, :implementation_specific_error}
      0x84 -> {:refused, :unsupported_protocol_version}
      0x85 -> {:refused, :client_identifier_not_valid}
      0x86 -> {:refused, :bad_user_name_or_password}
      0x87 -> {:refused, :not_authorized}
      0x88 -> {:refused, :server_unavailable}
      0x89 -> {:refused, :server_busy}
      0x8A -> {:refused, :banned}
      0x8C -> {:refused, :bad_authentication_method}
      0x90 -> {:refused, :topic_name_invalid}
      0x95 -> {:refused, :packet_too_large}
      0x97 -> {:refused, :quota_exceeded}
      0x99 -> {:refused, :payload_format_invalid}
      0x9A -> {:refused, :retain_not_supported}
      0x9B -> {:refused, :qos_not_supported}
      0x9C -> {:refused, :use_another_server}
      0x9D -> {:refused, :server_moved}
      0x9F -> {:refused, :connection_rate_exceeded}
    end
  end

  defimpl Tortoise.Encodable do
    def encode(%Package.Connack{} = t, _opts) do
      [
        Package.Meta.encode(t.__META__),
        Package.variable_length_encode([
          <<0::7, flag(t.session_present)::1, to_reason_code(t.reason)::8>>,
          Package.Properties.encode(t.properties)
        ])
      ]
    end

    defp to_reason_code(:success), do: 0x00

    defp to_reason_code({:refused, reason}) do
      case reason do
        :unspecified_error -> 0x80
        :malformed_packet -> 0x81
        :protocol_error -> 0x82
        :implementation_specific_error -> 0x83
        :unsupported_protocol_version -> 0x84
        :client_identifier_not_valid -> 0x85
        :bad_user_name_or_password -> 0x86
        :not_authorized -> 0x87
        :server_unavailable -> 0x88
        :server_busy -> 0x89
        :banned -> 0x8A
        :bad_authentication_method -> 0x8C
        :topic_name_invalid -> 0x90
        :packet_too_large -> 0x95
        :quota_exceeded -> 0x97
        :payload_format_invalid -> 0x99
        :retain_not_supported -> 0x9A
        :qos_not_supported -> 0x9B
        :use_another_server -> 0x9C
        :server_moved -> 0x9D
        :connection_rate_exceeded -> 0x9F
      end
    end

    defp flag(f) when f in [0, nil, false], do: 0
    defp flag(_), do: 1
  end

  if Code.ensure_loaded?(StreamData) do
    defimpl Tortoise.Generatable do
      import StreamData

      def generate(%type{__META__: _meta} = package) do
        values = package |> Map.from_struct()

        fixed_list(Enum.map(values, &constant(&1)))
        |> bind(&gen_reason/1)
        |> bind(&gen_session_present/1)
        |> bind(&gen_properties/1)
        |> bind(fn data ->
          fixed_map([
            {:__struct__, type}
            | for({k, v} <- data, do: {k, constant(v)})
          ])
        end)
      end

      @refusals [
        :unspecified_error,
        :malformed_packet,
        :protocol_error,
        :implementation_specific_error,
        :unsupported_protocol_version,
        :client_identifier_not_valid,
        :bad_user_name_or_password,
        :not_authorized,
        :server_unavailable,
        :server_busy,
        :banned,
        :bad_authentication_method,
        :topic_name_invalid,
        :packet_too_large,
        :quota_exceeded,
        :payload_format_invalid,
        :retain_not_supported,
        :qos_not_supported,
        :use_another_server,
        :server_moved,
        :connection_rate_exceeded
      ]

      defp gen_reason(values) do
        case Keyword.pop(values, :reason) do
          {nil, values} ->
            fixed_list([
              {
                constant(:reason),
                StreamData.frequency([
                  {60, constant(:success)},
                  {40, tuple({constant(:refused), one_of(@refusals)})}
                ])
              }
              | Enum.map(values, &constant(&1))
            ])

          {{:refused, nil}, values} ->
            fixed_list([
              {:reason, tuple({constant(:refused), one_of(@refusals)})}
              | Enum.map(values, &constant(&1))
            ])

          {:success, _} ->
            constant(values)

          {{:refused, refusal_reason}, _} when refusal_reason in @refusals ->
            constant(values)
        end
      end

      defp gen_session_present(values) do
        case Keyword.get(values, :reason) do
          :success ->
            case Keyword.pop(values, :session_present) do
              {nil, values} ->
                fixed_list([
                  {constant(:session_present), boolean()}
                  | Enum.map(values, &constant(&1))
                ])

              {_passthrough, _} ->
                constant(values)
            end

          {:refused, _refusal_reason} ->
            # There will not be a session if the connection is refused
            constant(Keyword.put(values, :session_present, false))
        end
      end

      defp gen_properties(values) do
        case Keyword.pop(values, :properties) do
          {nil, values} ->
            properties =
              uniq_list_of(
                one_of([
                  # here we allow stings with a byte size of zero; don't
                  # know if that is a problem according to the spec. Let's
                  # handle that situation just in case:
                  {constant(:user_property), {string(:printable), string(:printable)}},
                  {constant(:assigned_client_identifier),
                   string(:printable, min_length: 1, max_length: 23)},
                  {constant(:maximum_packet_size), integer(1..0xFFFFFFFF)},
                  {constant(:maximum_qos), integer(0..1)},
                  {constant(:reason_string), string(:printable)},
                  {constant(:receive_maximum), integer(0..0xFFFF)},
                  {constant(:retain_available), boolean()},
                  # TODO don't know if zero is a valid keep alive
                  {constant(:server_keep_alive), integer(0..0xFFFF)},
                  {constant(:session_expiry_interval), integer(0..0xFFFF)},
                  {constant(:shared_subscription_available), boolean()},
                  {constant(:subscription_identifiers_available), boolean()},
                  {constant(:topic_alias_maximum), integer(0..0xFFFF)},
                  {constant(:wildcard_subscription_available), boolean()}

                  # TODO, generator that generate valid server references
                  # {constant(:server_reference), boolean()},
                  # TODO, generator that generate valid response info
                  # {constant(:response_information), boolean()},
                  # TODO, generate auth data and methods
                  # {constant(:authentication_data), boolean()},
                  # {constant(:authentication_method), boolean()}
                ]),
                uniq_fun: &uniq/1,
                max_length: 5
              )

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
