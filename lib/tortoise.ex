defmodule Tortoise do
  use Application

  alias Tortoise.Connection.Transmitter

  @moduledoc """
  Documentation for Tortoise.
  """

  @doc """
  Start the application supervisor
  """
  def start(:normal, _args) do
    import Supervisor.Spec, warn: false

    children = [
      supervisor(Registry, [[keys: :unique, name: Registry.Tortoise]])
      # worker(Tortoise.InFlightRegistry, [[name: Tortoise.InFlightRegistry]])
    ]

    # read configuration and start connections
    # start with client_id, and driver from config

    opts = [strategy: :one_for_one, name: Tortoise.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Publish a message to the MQTT broker
  """
  def publish(client_id, topic, payload) do
    Transmitter.cast(client_id, %Tortoise.Package.Publish{
      identifier: nil,
      topic: topic,
      payload: payload,
      qos: 0,
      retain: false
    })
  end
end
