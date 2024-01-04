Inventory Trim
===========

You know when your main inventory is jammed with slots containing small numbers of surplus items? You've picked up few pieces of belt and a chest, and now you've got slots containing 2 extra Inserters, 6 pieces of damaged Wall, 9 pieces of Iron Plate and ... well, junk.

This mod enables *inventory trimming*: your main inventory is scanned periodically to see if there are slots that are being used inefficiently, and throws their contents into the logistics trash. Hurrah, no more clicky-clicky to get rid of the rubbish!

Features
--------

* Trims away items in small stacks that are taking up slots.
* Identifies less useful items to trim first, eg intermediate or raw materials, non-placeable items, damaged items.
* Keeps at least 10 slots free (configurable) by trimming more assertively, and tries HARD to keep 2 slots free (also configurable).
* Sensitive to logistic request levels and inventory slot filters.
* Won't remove your last stack of some item, unless you tell it to.
* Can be disabled on a per-player basis, and turns off when your auto-trash is turned off.
* Enabled by a cheap technology-tree item once you have logistics robots.

Rationale
------

I keep finding, from around mid-game, that my inventory is always sort of full, and that many slots are occupied with low value items. I can set logistics maximums to get rid of things, but they feel like a heavy-handed and broad-brush solution. I don't mind having 100 Inserters (2 stacks) but I do mind having 53 - also 2 stacks - and then finding I'm out of space. This mod aims to fix that, whilst being more sensitive to circumstances.

Trimming is only meaningful in a world where you have logistics and auto-trash, so it is assumed that you are at a point in the game where carrying small items of stuff isn't so critical. Much of your inventory content is likely to be under automated configuration anyway. The aim of trimming should be to deal with the annoyance of never having much space and pruning the junk.


Detailed Operation
-------

1. Determine whether the player is eligible for trimming (are they a real player with a character and an inventory? do they have the logistics tech?, is their inventory > 60% full?)
2. Merge incompletely filled item slots to the left-most slots (in case user has disabled "Interface: Always keep Main Inventory sorted" setting). Basic tidy-up.
3. For each item, determine: which slots it occupies; any "middle-click" filter slots; logistics request minimum if any; damaged items slots. Non-stacking items (blueprints, remotes, etc) are completely left alone.
4. There's no point emptying slots that go below the request minimum, or the capacity off filter slots, so determine how many slots we _could_ clear. Any slots above that number are considered "excess" slots, and are candidates for clearing. There's no point trimming non-excess slots, because bots will just refill them. Plus, the minimum number of stacks is clamped to at least 1, so it won't clean you out completely (though, see Tricks below).
5. Iterate all items: assign an "importance" score to each excess slot based on the item's characteristics, where the goal is to clear away low importance items. Is it:
    * partially filled, as a proportion of full stack-size? More full == more important.
    * a raw/intermediate item? such items are considered low importance.
    * placeable? items that can be placed (like assembly machines or rail) are considered more important.
    * logistics minimum requested? if you have a logistics request set up, then we guess that you're less likely to mind losing the _excess above that minimum_ because bots will bring you more.
    * on the right? Leftmost stacks are assigned higher importance.
6. Sort the slot-trimming actions by increasing importance, so we can work through performing more and more aggressive trimming as required.
7. Pick an importance threshold based on how many free slots there are compared to the limits in settings, and apply trimming actions below that threshold.
8. Display the on-screen trimming text to show what is happening.
9. Scan again in 10 seconds.

Tricks
------

Generally the trimmer should remove unwanted items and leave the rest. It's possible that sometimes it is over- or under- aggressive, and so there are some tricks to affect its choices.

* The trimmer will normally not steal your final stack of some item: the min slot count is normally set to 1 (or more, with filters or logistics requests). There are some items which you might _always_ want to be trimmable (sulfur, copper wire?) - in which case: _set the logistics minimum to zero!_ A request minimum of zero is usually useless because it's what you get without setting the request, but this mod sees it and removes the "at least 1" clamp.
* If the trimmer is stealing items that you value, then consider setting a logistics request for that item.
* If you middle-click to set a slot filter, you can prevent the trimmer from touching that slot at all.
* The trimmer is turned off automatically when you disable the _Personal Logistics and Auto-trash_ checkbox on the Logistics configuration panel.
* There are settings for adjusting thresholds, configurable on a per-user basis.
* Don't forget you can always clear stacks manually!
