I want it to get rid of crappy items like Sulfur and Copper Wire, but it always leaves at least one stack. Is there a trick?
------------

Why yes! Normally, it never trims away your very last stack of anything, because we can't tell if it was something you wanted to keep (eg red/green wire). But if you set a logistics request for the item with a _minimum set to zero_ (which is normally meaningless), the trimmer will know you really are happy for a minimum of zero slots and will clear them out.

This is different from setting a max of zero, which will auto-trash completely. The trimmer will only clean you out if the stacking is clearly inefficient and you are under space pressure.

I want to move lots of Rail (or landfill, or belt etc) from this chest to that chest and it keeps emptying my inventory! Help!
-------

Temporarily turn off the _Logistics requests and auto-trash_ checkbox (on the Logistics UI). If you find you do this a lot and it's annoying, there's a setting to decrease the number of slots being kept free (default: 10). There's another setting ("Consider fullness a key factor...") that prioritizes retaining fuller stacks - I've not played with it much, but if you feel adventurous, try increasing it, 1.2, 1.5, 2.0. 
