defmodule Tortoise.Handler.Logger do
  @moduledoc false

  require Logger

  alias Tortoise.Package

  use Tortoise.Handler

  defstruct []
  alias __MODULE__, as: State

  @impl true
  def init(_opts) do
    Logger.info("Initializing handler")
    {:ok, %State{}}
  end

  @impl true
  def connection(:up, state) do
    Logger.info("Connection has been established")
    {:cont, state}
  end

  def connection(:down, state) do
    Logger.warn("Connection has been dropped")
    {:cont, state}
  end

  def connection(:terminating, state) do
    Logger.warn("Connection is terminating")
    {:cont, state}
  end

  @impl true
  def handle_connack(%Package.Connack{reason: :success}, state) do
    Logger.info("Successfully connected to the server")
    {:cont, state}
  end

  def handle_connack(%Package.Connack{reason: {:refused, refusal}}, state) do
    Logger.error("Server refused connection: #{inspect refusal}")
    {:cont, state}
  end

  @impl true
  def handle_suback(%Package.Subscribe{} = subscribe, %Package.Suback{} = suback, state) do
    for {{topic, opts}, result} <- Enum.zip(subscribe.topics, suback.acks) do
      case {opts[:qos], result} do
        {qos, {:ok, qos}} ->
          Logger.info("Subscribed to #{topic} with the expected qos: #{qos}")

        {req_qos, {:ok, accepted_qos}} ->
          Logger.warn("Subscribed to #{topic} with QoS #{req_qos} but got accepted as #{accepted_qos}")

        {_, {:error, reason}} ->
          Logger.error("Failed to subscribe to topic: #{topic} reason: #{inspect reason}")
      end
    end
    {:cont, state}
  end

  @impl true
  def handle_unsuback(%Package.Unsubscribe{} = unsubscribe, %Package.Unsuback{} = unsuback, state) do
    for {topic, result} <- Enum.zip(unsubscribe.topics, unsuback.results) do
      case result do
        :success ->
          Logger.info("Successfully unsubscribed from #{topic}")
      end
    end
    {:cont, state}
  end

  @impl true
  def handle_publish(topic, %Package.Publish{} = publish, state) do
    Logger.info("#{Enum.join(topic, "/")} #{inspect(publish)}")
    {:cont, state}
  end

  @impl true
  def handle_puback(%Package.Puback{} = puback, state) do
    Logger.info("Puback: #{puback.identifier}")
    {:cont, state}
  end

  @impl true
  def handle_pubrec(%Package.Pubrec{} = pubrec, state) do
    Logger.info("Pubrec: #{pubrec.identifier}")
    {:cont, state}
  end

  @impl true
  def handle_pubcomp(%Package.Pubcomp{} = pubcomp, state) do
    Logger.info("Pubcomp: #{pubcomp.identifier}")
    {:cont, state}
  end

  @impl true
  def handle_disconnect(%Package.Disconnect{} = disconnect, state) do
    Logger.info("Received disconnect from server #{inspect(disconnect)}")
    {:cont, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.warn("Client has been terminated with reason: #{inspect(reason)}")
    :ok
  end
end
