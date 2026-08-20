module Lib.Ticket exposing (Ticket, initial, next)


type Ticket
    = Ticket Int


initial : Ticket
initial =
    Ticket 0


next : Ticket -> Ticket
next (Ticket value) =
    Ticket (value + 1)
