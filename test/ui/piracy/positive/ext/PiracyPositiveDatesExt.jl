module PiracyPositiveDatesExt

using PiracyPositive: PiracyPositive, Box
using Dates: Dates

# Package type: extension owns it.
Dates.year(box::Box) = 0

# Package function: extension owns it.
PiracyPositive.describe(date::Dates.Date) = "date"

Base.isone(date::Dates.Date) = false

end
