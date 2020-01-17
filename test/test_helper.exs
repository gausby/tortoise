defmodule Tortoise.TestGenerators do
  @moduledoc """
  EQC generators for generating variables and data structures useful
  for testing MQTT
  """
  use EQC.ExUnit

  alias Tortoise.Package

  def gen_topic() do
    let topic_list <- non_empty(list(5, gen_topic_level())) do
      Enum.join(topic_list, "/")
    end
  end

  def gen_topic_filter() do
    let topic_list <- non_empty(list(5, gen_topic_level())) do
      let {_matching?, filter} <- gen_filter_from_topic(topic_list) do
        Enum.join(filter, "/")
      end
    end
  end

  defp gen_topic_level() do
    such_that topic <- non_empty(utf8()) do
      not String.contains?(topic, ["/", "+", "#"])
    end
  end

  # - - -
  defp gen_filter_from_topic(topic) do
    {_matching?, _filter} = gen_filter(:cont, true, topic, [])
  end

  defp gen_filter(_status, matching?, _, ["#" | _] = acc) do
    let(result <- Enum.reverse(acc), do: {matching?, result})
  end

  defp gen_filter(:stop, matching?, [t], acc) do
    let(result <- Enum.reverse([t | acc]), do: {matching?, result})
  end

  defp gen_filter(:stop, _matching?, _topic_list, acc) do
    let(result <- Enum.reverse(acc), do: {false, result})
  end

  defp gen_filter(status, matching?, [], acc) do
    frequency([
      {20, {matching?, lazy(do: Enum.reverse(acc))}},
      {5, gen_extra_filter_topic(status, matching?, acc)}
    ])
  end

  defp gen_filter(status, matching?, [t | ts], acc) do
    frequency([
      # keep
      {15, gen_filter(status, matching?, ts, [t | acc])},
      # one level filter
      {20, gen_filter(status, matching?, ts, ["+" | acc])},
      # mutate
      {10, gen_filter(status, false, ts, [alter_topic_level(t) | acc])},
      # multi-level filter
      {5, gen_filter(status, matching?, [], ["#" | acc])},
      # early bail out
      {5, gen_filter(:stop, matching?, [t | ts], acc)}
    ])
  end

  defp gen_extra_filter_topic(status, _matching?, acc) do
    let extra_topic <- gen_topic_level() do
      gen_filter(status, false, [extra_topic], acc)
    end
  end

  # Given a specific topic level return a different one
  defp alter_topic_level(topic_level) do
    such_that mutation <- gen_topic_level() do
      mutation != topic_level
    end
  end

  # --------------------------------------------------------------------
  def gen_identifier() do
    choose(0x0001, 0xFFFF)
  end

  def gen_qos() do
    choose(0, 2)
  end

  @doc """
  Generate a valid connect message
  """
  def gen_connect() do
    let will <-
          oneof([
            nil,
            %Package.Publish{
              topic: gen_topic(),
              payload: oneof([non_empty(binary()), nil]),
              qos: gen_qos(),
              retain: bool(),
              properties: [receive_maximum: 201]
            }
          ]) do
      # zero byte client id is allowed, but clean session should be set to true
      let connect <- %Package.Connect{
            # The Server MUST allow ClientIds which are between 1 and 23
            # UTF-8 encoded bytes in length, and that contain only the
            # characters
            # "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
            # [MQTT-3.1.3-5].

            # The Server MAY allow ClientId’s that contain more than 23
            # encoded bytes. The Server MAY allow ClientId’s that contain
            # characters not included in the list given above.
            client_id: binary(),
            user_name: oneof([nil, utf8()]),
            password: oneof([nil, utf8()]),
            clean_start: bool(),
            keep_alive: choose(0, 65535),
            will: will,
            properties: [receive_maximum: 201]
          } do
        connect
      end
    end
  end

  @doc """
  Generate a valid connack (connection acknowledgement) message
  """
  def gen_connack() do
    let connack <- %Package.Connack{
          session_present: bool(),
          reason:
            oneof([
              :success,
              {:refused, :unspecified_error},
              {:refused, :malformed_packet},
              {:refused, :protocol_error},
              {:refused, :implementation_specific_error},
              {:refused, :unsupported_protocol_version},
              {:refused, :client_identifier_not_valid},
              {:refused, :bad_user_name_or_password},
              {:refused, :not_authorized},
              {:refused, :server_unavailable},
              {:refused, :server_busy},
              {:refused, :banned},
              {:refused, :bad_authentication_method},
              {:refused, :topic_name_invalid},
              {:refused, :packet_too_large},
              {:refused, :quota_exceeded},
              {:refused, :payload_format_invalid},
              {:refused, :retain_not_supported},
              {:refused, :qos_not_supported},
              {:refused, :use_another_server},
              {:refused, :server_moved},
              {:refused, :connection_rate_exceeded}
            ])
        } do
      connack
    end
  end

  @doc """
  Generate a valid publish message.

  A publish message with a quality of zero will not have an identifier
  or ever be a duplicate message, so we generate the quality of
  service first and decide if we should generate values for those
  values depending on the value of the generated QoS.
  """
  def gen_publish() do
    let qos <- gen_qos() do
      %{
        do_gen_publish(qos)
        | topic: gen_topic(),
          payload: oneof([non_empty(binary()), nil]),
          retain: bool()
      }
      |> gen_publish_properties()
    end
  end

  defp do_gen_publish(0) do
    %Package.Publish{identifier: nil, qos: 0, dup: false}
  end

  defp do_gen_publish(qos) do
    %Package.Publish{
      identifier: gen_identifier(),
      qos: qos,
      dup: bool()
    }
  end

  defp gen_publish_properties(%Package.Publish{} = publish) do
    allowed_properties = [
      :payload_format_indicator,
      :message_expiry_interval,
      :topic_alias,
      :response_topic,
      :correlation_data,
      :user_property,
      :subscription_identifier,
      :content_type
    ]

    let properties <- list(5, oneof(allowed_properties)) do
      # @todo only user_properties and subscription_identifiers are allowed multiple times
      properties = Enum.map(properties, &gen_property_value/1)
      %Package.Publish{publish | properties: properties}
    end
  end

  @doc """
  Generate a valid subscribe message.

  The message will get populated with one or more topic filters, each
  with a quality of service between 0 and 2.
  """
  def gen_subscribe() do
    let subscribe <- %Package.Subscribe{
          identifier: gen_identifier(),
          topics: non_empty(list({gen_topic_filter(), gen_subscribe_opts()})),
          # todo, add properties
          properties: []
        } do
      subscribe
    end
  end

  # @todo improve this generator
  def gen_subscribe_opts() do
    let {qos, no_local, retain_as_published, retain_handling} <-
          {gen_qos(), bool(), bool(), choose(0, 3)} do
      [
        qos: qos,
        no_local: no_local,
        retain_as_published: retain_as_published,
        retain_handling: retain_handling
      ]
    end
  end

  def gen_suback() do
    let suback <- %Package.Suback{
          identifier: choose(0x0001, 0xFFFF),
          acks:
            non_empty(
              list(
                oneof([
                  {:ok, gen_qos()},
                  {:error,
                   oneof([
                     :unspecified_error,
                     :implementation_specific_error,
                     :not_authorized,
                     :topic_filter_invalid,
                     :packet_identifier_in_use,
                     :quota_exceeded,
                     :shared_subscriptions_not_supported,
                     :subscription_identifiers_not_supported,
                     :wildcard_subscriptions_not_supported
                   ])}
                ])
              )
            ),
          # todo, add generators for [:reason_string, :user_property]
          properties: []
        } do
      suback
    end
  end

  @doc """
  Generate a valid unsubscribe message.
  """
  def gen_unsubscribe() do
    let unsubscribe <- %Package.Unsubscribe{
          identifier: gen_identifier(),
          topics: non_empty(list(gen_topic_filter())),
          properties: []
        } do
      unsubscribe
    end
  end

  def gen_unsuback() do
    let unsuback <- %Package.Unsuback{
          identifier: gen_identifier(),
          results:
            non_empty(
              list(
                oneof([
                  :success,
                  {:error,
                   oneof([
                     :no_subscription_existed,
                     :unspecified_error,
                     :implementation_specific_error,
                     :not_authorized,
                     :topic_filter_invalid,
                     :packet_identifier_in_use
                   ])}
                ])
              )
            ),
          # todo, generate :reason_string and :user_property
          properties: []
        } do
      unsuback
    end
  end

  def gen_puback() do
    # todo, make this generator generate properties and other reasons
    let puback <- %Package.Puback{
          identifier: gen_identifier(),
          reason: :success,
          properties: []
        } do
      puback
    end
  end

  def gen_pubcomp() do
    let pubcomp <- %Package.Pubcomp{
          identifier: gen_identifier(),
          reason: {:refused, :packet_identifier_not_found},
          properties: []
        } do
      pubcomp
    end
  end

  def gen_pubrel() do
    # todo, improve this generator
    let pubrel <- %Package.Pubrel{
          identifier: gen_identifier(),
          reason: :success,
          properties: []
        } do
      pubrel
    end
  end

  def gen_pubrec() do
    # todo, improve this generator
    let pubrec <- %Package.Pubrec{
          identifier: gen_identifier(),
          reason: :success,
          properties: []
        } do
      pubrec
    end
  end

  def gen_disconnect() do
    let disconnect <-
          %Package.Disconnect{
            reason:
              oneof([
                :normal_disconnection,
                :disconnect_with_will_message,
                :unspecified_error,
                :malformed_packet,
                :protocol_error,
                :implementation_specific_error,
                :not_authorized,
                :server_busy,
                :server_shutting_down,
                :keep_alive_timeout,
                :session_taken_over,
                :topic_filter_invalid,
                :topic_name_invalid,
                :receive_maximum_exceeded,
                :topic_alias_invalid,
                :packet_too_large,
                :message_rate_too_high,
                :quota_exceeded,
                :administrative_action,
                :payload_format_invalid,
                :retain_not_supported,
                :qos_not_supported,
                :use_another_server,
                :server_moved,
                :shared_subscriptions_not_supported,
                :connection_rate_exceeded,
                :maximum_connect_time,
                :subscription_identifiers_not_supported,
                :wildcard_subscriptions_not_supported
              ])
          } do
      %Package.Disconnect{disconnect | properties: gen_properties(disconnect)}
    end
  end

  def gen_auth() do
    let auth <-
          %Package.Auth{
            reason: oneof([:success, :continue_authentication, :re_authenticate])
          } do
      %Package.Auth{auth | properties: gen_properties(auth)}
    end
  end

  def gen_properties(%Package.Disconnect{reason: :normal_disconnection}) do
    []
  end

  def gen_properties(%{}) do
    []
  end

  def gen_properties() do
    let properties <-
          list(
            5,
            oneof([
              :payload_format_indicator,
              :message_expiry_interval,
              :content_type,
              :response_topic,
              :correlation_data,
              :subscription_identifier,
              :session_expiry_interval,
              :assigned_client_identifier,
              :server_keep_alive,
              :authentication_method,
              :authentication_data,
              :request_problem_information,
              :will_delay_interval,
              :request_response_information,
              :response_information,
              :server_reference,
              :reason_string,
              :receive_maximum,
              :topic_alias_maximum,
              :topic_alias,
              :maximum_qos,
              :retain_available,
              :user_property,
              :maximum_packet_size,
              :wildcard_subscription_available,
              :subscription_identifier_available,
              :shared_subscription_available
            ])
          ) do
      Enum.map(properties, &gen_property_value/1)
    end
  end

  def gen_property_value(type) do
    case type do
      :payload_format_indicator -> {type, oneof([0, 1])}
      :message_expiry_interval -> {type, choose(0, 4_294_967_295)}
      :content_type -> {type, utf8()}
      :response_topic -> {type, gen_topic()}
      :correlation_data -> {type, binary()}
      :subscription_identifier -> {type, choose(1, 268_435_455)}
      :session_expiry_interval -> {type, choose(1, 268_435_455)}
      :assigned_client_identifier -> {type, utf8()}
      :server_keep_alive -> {type, choose(0x0000, 0xFFFF)}
      :authentication_method -> {type, utf8()}
      :authentication_data -> {type, binary()}
      :request_problem_information -> {type, bool()}
      :will_delay_interval -> {type, choose(0, 4_294_967_295)}
      :request_response_information -> {type, bool()}
      :response_information -> {type, utf8()}
      :server_reference -> {type, utf8()}
      :reason_string -> {type, utf8()}
      :receive_maximum -> {type, choose(0x0001, 0xFFFF)}
      :topic_alias_maximum -> {type, choose(0x0000, 0xFFFF)}
      :topic_alias -> {type, choose(0x0001, 0xFFFF)}
      :maximum_qos -> {type, oneof([0, 1])}
      :retain_available -> {type, bool()}
      :user_property -> {type, {utf8(), utf8()}}
      :maximum_packet_size -> {type, choose(1, 268_435_455)}
      :wildcard_subscription_available -> {type, bool()}
      :subscription_identifier_available -> {type, bool()}
      :shared_subscription_available -> {type, bool()}
    end
  end
end

# make certs for tests using the SSL transport
:ok = :ct_helper.make_certs_in_ets()

{:ok, _} = Tortoise.Integration.TestTCPTunnel.start_link()

ExUnit.start(capture_log: true)
