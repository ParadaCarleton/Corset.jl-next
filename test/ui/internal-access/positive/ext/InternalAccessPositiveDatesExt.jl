module InternalAccessPositiveDatesExt

using InternalAccessPositive: InternalAccessPositive
using Dates: Dates

specifiers() = Dates.CONVERSION_SPECIFIERS
# Extension reaches parent package internals: own package.
parent_index(dims::Tuple) = InternalAccessPositive.index(dims, 1)
import InternalAccessPositive: body

end
