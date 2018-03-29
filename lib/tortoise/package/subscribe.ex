defmodule Tortoise.Package.Subscribe do
  @opcode 8

  alias Tortoise.Package

  @type package_identifier :: 0x0001..0xFFFF
  @type qos :: 0 | 1 | 2
  @type topic :: {binary(), qos}
  @type topics :: [topic]

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            identifier: package_identifier() | nil,
            topics: topics()
          }
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0b0010},
            identifier: nil,
            topics: []

  @spec decode(binary()) :: t
  def decode(<<@opcode::4, 0b0010::4, length_prefixed_payload::binary>>) do
    payload = drop_length(length_prefixed_payload)
    <<identifier::big-integer-size(16), topics::binary>> = payload
    topic_list = decode_topics(topics)
    %__MODULE__{identifier: identifier, topics: topic_list}
  end

  defp drop_length(payload) do
    case payload do
      <<0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
    end
  end

  defp decode_topics(<<>>), do: []

  defp decode_topics(<<length::big-integer-size(16), rest::binary>>) do
    <<topic::binary-size(length), return_code::integer-size(8), rest::binary>> = rest
    [{topic, return_code}] ++ decode_topics(rest)
  end

  # PROTOCOLS ==========================================================
  defimpl Tortoise.Encodable do
    @spec encode(Package.Subscribe.t()) :: iolist()
    def encode(%Package.Subscribe{identifier: identifier} = t)
        when identifier in 0x0001..0xFFFF do
      [
        Package.Meta.encode(t.__META__),
        Package.variable_length_encode([
          <<identifier::big-integer-size(16)>>,
          encode_topics(t.topics)
        ])
      ]
    end

    defp encode_topics(topics) do
      Enum.map(topics, fn {topic, qos} ->
        [Package.length_encode(topic), <<0::6, qos::2>>]
      end)
    end
  end

  defimpl Enumerable do
    def reduce(%Package.Subscribe{topics: topics}, acc, fun) do
      Enumerable.List.reduce(topics, acc, fun)
    end

    def member?(%Package.Subscribe{topics: topics}, value) do
      {:ok, Enum.member?(topics, value)}
    end

    def count(%Package.Subscribe{topics: topics}) do
      {:ok, Enum.count(topics)}
    end

    def slice(_) do
      # todo
      {:error, __MODULE__}
    end
  end

  defimpl Collectable do
    def into(%Package.Subscribe{topics: topics} = source) do
      {Enum.into(topics, %{}),
       fn
         acc, {:cont, {<<topic::binary>>, qos}} when qos in 0..2 ->
           Map.update(acc, topic, qos, fn
             current_qos when qos > current_qos ->
               qos

             current_qos ->
               current_qos
           end)

         acc, {:cont, <<topic::binary>>} ->
           Map.put_new(acc, topic, 0)

         acc, :done ->
           %{source | topics: Map.to_list(acc)}

         _, :halt ->
           :ok
       end}
    end
  end
end
