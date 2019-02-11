# New Features in this Fork

see [TODO](/TODO.md) for planned features

## Screenshots worth a thousand words

<a href='/Documentation/Screenshots%20Features/Foodpicker%20-%20Camera.png'><img src='/Documentation/Screenshots%20Features/Foodpicker%20-%20Camera.png?raw=true' alt='Documentation/Screenshots%20Features/Foodpicker%20-%20Camera.png' width='170'></a>
<a href='/Documentation/Screenshots%20Features/Foodpicker%20-%20Drinks.png'><img src='/Documentation/Screenshots%20Features/Foodpicker%20-%20Drinks.png?raw=true' alt='Documentation/Screenshots%20Features/Foodpicker%20-%20Drinks.png' width='170'></a>
<a href='/Documentation/Screenshots%20Features/Foodpicker%20-%20Multiple.png'><img src='/Documentation/Screenshots%20Features/Foodpicker%20-%20Multiple.png?raw=true' alt='Documentation/Screenshots%20Features/Foodpicker%20-%20Multiple.png' width='170'></a>
<a href='/Documentation/Screenshots%20Features/Foodpicker%20-%20Single.png'><img src='/Documentation/Screenshots%20Features/Foodpicker%20-%20Single.png?raw=true' alt='Documentation/Screenshots%20Features/Foodpicker%20-%20Single.png' width='170'></a>
<a href='/Documentation/Screenshots%20Features/QuickCarbs%20-%20Default.png'><img src='/Documentation/Screenshots%20Features/QuickCarbs%20-%20Default.png?raw=true' alt='Documentation/Screenshots%20Features/QuickCarbs%20-%20Default.png' width='170'></a>
<a href='/Documentation/Screenshots%20Features/Settings%20-%20AutoBolus.png'><img src='/Documentation/Screenshots%20Features/Settings%20-%20AutoBolus.png?raw=true' alt='Documentation/Screenshots%20Features/Settings%20-%20AutoBolus.png' width='170'></a>
<a href='/Documentation/Screenshots%20Features/Settings%20-%20Disconnect%20Sports.png'><img src='/Documentation/Screenshots%20Features/Settings%20-%20Disconnect%20Sports.png?raw=true' alt='Documentation/Screenshots%20Features/Settings%20-%20Disconnect%20Sports.png' width='170'></a>
<a href='/Documentation/Screenshots%20Features/Settings%20-%20Expertmode.png'><img src='/Documentation/Screenshots%20Features/Settings%20-%20Expertmode.png?raw=true' alt='Documentation/Screenshots%20Features/Settings%20-%20Expertmode.png' width='170'></a>
<a href='/Documentation/Screenshots%20Features/Settings%20-%20MaxIOB%20MinBasal.png'><img src='/Documentation/Screenshots%20Features/Settings%20-%20MaxIOB%20MinBasal.png?raw=true' alt='Documentation/Screenshots%20Features/Settings%20-%20MaxIOB%20MinBasal.png' width='170'></a>
<a href='/Documentation/Screenshots%20Features/Settings%20-%20MinBasal.png'><img src='/Documentation/Screenshots%20Features/Settings%20-%20MinBasal.png?raw=true' alt='Documentation/Screenshots%20Features/Settings%20-%20MinBasal.png' width='170'></a>
<a href='/Documentation/Screenshots%20Features/Status%20-%20Disconnected.png'><img src='/Documentation/Screenshots%20Features/Status%20-%20Disconnected.png?raw=true' alt='Documentation/Screenshots%20Features/Status%20-%20Disconnected.png' width='170'></a>
<a href='/Documentation/Screenshots%20Features/Status%20-%20MealInformation%20-%20Automatic%20Bolus.png'><img src='/Documentation/Screenshots%20Features/Status%20-%20MealInformation%20-%20Automatic%20Bolus.png?raw=true' alt='Documentation/Screenshots%20Features/Status%20-%20MealInformation%20-%20Automatic%20Bolus.png' width='170'></a>

## Automated Bolus Core Infrastructure

- Give automated bolus of 70% of the recommended value.
  Kind of like SMBs, but faster.
- Minium of 0.2 units
- Do not high temp Basal when doing this

## Bolus Guard Features

- Not exceed recommended amount
- Prefill correct amount in the field
- take Maximum Insulin on board into account
- Round to 0.1
- No touch id
- Disable bolus and bolus button if a bolus is in progress

## Display ongoing Bolus State (for automated and manual)

-  Display of Bolus and interaction with StatusViewController
-  Also display carb recommendations

## Kids/Caregive vs. Expert Mode

-  Disable settings by default
-  Need long touch of 2 seconds to enable
-  Disable any Bolus recommendation modification as well as
   Carb or Insulin Edits

## Automated Bolus

-  Maximum IOB
-  Minimum Basal Rate
-  Safe distance of Bolus'

## New Carb Entry View (QuickCarbs)

-  Focus on the basics and +- 5 carbs increments
-  In the future allow manual glucose entry.
-  Manual Glucose Entry (plus LoopManager handling if necessary)


## Meal Information on main screen

-  Shows individually entered carbs to quickly check what
   was entered, also allow undo of last entry, if no
   Bolus was given.

## FoodManager

-  Add a food database with pictures and slider to select
   amount of food for easy entry of common food, even for
   the illiterate.  Also keeps better track of what was
   eaten.
-  Supports liquid, single and multiple selection
-  Absorption time depending on food.
-  Pre-programmed carb ratios

## Minimum Basal Rate

- Allow configuring the minimum basal to prevent going
  down completely to zero for long amounts of time.

## Note taking feature

- Add a button to the status bar allowing adding random
  notes to be taken and logged to Nightscout

## Workout - Disconnect Pump Target

- Sets a minimal basal rate to mimic effect of no insulin
  while the pump is not attached.  Could probably be improved
  by adding a Zero target for this time.  Also prevents
  unintentional automatic bolus.

## Logging of Site Change and Reservoir Change to Nightscout

- Logs customs notes
- Treats "Canula fill" as a Site Change
- Treats "Reservoir fill" as an Insulin Change

## Logging of current Profile to Nightscout

- Automatically log the current Basal, CarbRatio and Target
  settings to Nightscout.
- Store in Nightscout:  Minimum Basal Rates, Workout/Meal Targets, G5 Transmitter ID, Pump ID

## Predictive Low Notifications

-  Generate a Notification if the predicted glucose value is
   going to be below the guard value in the next 30 minutes.

## Retries of Pump operations

-  TempBasal, Bolus, readPumpStatus will all be (safely)
   retried to prevent the amount of times the user
   will need to manually retry and improve the chance of
   a successful loop with more challenging RF
   environments.

## Automated Time change on pump

-  If the difference is more than a few seconds, synchronize time.

## Recommend Bolus based on Carbs if no glucose is available

-  Implemented and working.  Use at your own risk.  Won't trigger
   an automated Bolus.

## Bluetooth restart

-  Triggered if either Glucose or Rileylink is missing.  Not super reliable.

## Logging of G5/6 Sensor information

-  Logs sensor start date and calibration information to Nightscout.

# Additional Features for consideration

## Don't turn off bolus below min guard

Just reduce it a lot.

## Display more info for bolus

Like the progress, especially for bigger bolus amounts would be useful.

