##### event listen

##### Syntax
| Syntax | `event.listen(event: string, callback: function): boolean` |
| --- | --- |

##### Description
| Description | Register a new event listener that should be called for events with the specified name. |
| --- | --- |

##### Details
| Arguments | **event** - name of the signal to listen to. |
| --- | --- |
|  | **callback** - the function to call if this signal is received. The function will receive the event name it was registered for as first parameter, then all remaining parameters as defined by the [signal](component/signals.md) that caused the event. |
| Returns | `true` if the event was successfully registered, `false` if this function was already registered for this event type. |
