# test_ei.nim
import ../src/nimLibEi

proc main() =
  let ctx = newEiSender()
  echo "Ei context created: ", ctx.raw != nil
  echo "Is sender: ", ctx.raw.ei_is_sender()
  ctx.raw.ei_unref()  # Ручная очистка, если не используется RAII

main()
