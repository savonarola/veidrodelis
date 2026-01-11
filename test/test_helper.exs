Application.ensure_all_started(:veidrodelis)
ExUnit.start(exclude: [:slow])
Logger.configure(level: :info)
