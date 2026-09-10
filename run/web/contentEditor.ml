open Vdom

module type Provision = sig
  type 'inner_msg msg (* The type of messages that can be sent to the upper layer of the application. *)
  val push_up_msg : 'inner_msg -> 'inner_msg msg (* Function to push a message up to the upper layer of the application. *)

  (* Extra callback for the content editor widget. 
    The function to save the content to a file. It takes the file path and the content as arguments. *)
  val save_file : string -> string -> _ msg
end


module type Widget = sig
  type 'inner_msg msg
  type model
  type inner_msg
  val init : model
  val update : model -> inner_msg -> model * (inner_msg msg Cmd.t list)
  val view : model -> inner_msg msg vdom
end


module Make(Provision: Provision) : Widget with type 'inner_msg msg := 'inner_msg Provision.msg = struct

(* Definition of the vdom widget 'ContentEditor' *)
  type model = {
    content : string;
    editableMarkdown : bool;
    editableMode : bool;
    filePath : string;
  } (* the type of the application state *)
  
  type inner_msg =   (* the type of messages that can be sent to update the state *)
    | UpdateContent of string
    | ToggleMode of bool
    | SaveFile of string

  let view model =   (* the state->vdom rendering function *)
    let content_view = 
      if model.editableMode then
        Vdom.input ~a:[Vdom.Attr.value model.content; Vdom.Attr.on_input (fun s -> push_up_msg (UpdateContent s))] ()
      else
        Vdom.text model.content
    in
    let mode_toggle = 
      Vdom.button ~a:[Vdom.Attr.on_click (fun _ -> push_up_msg (ToggleMode (not model.editableMode)))] 
        (if model.editableMode then "Switch to View Mode" else "Switch to Edit Mode")
    in
    let save_button = 
      Vdom.button ~a:[Vdom.Attr.on_click (fun _ -> push_up_msg (SaveFile model.filePath))] "Save"
    in
    Vdom.div [
      content_view;
      mode_toggle;
      save_button;
    ]

  let init = {
    content = "";
    editableMarkdown = false;
    editableMode = false;
    filePath = "";
  }

  let update model = function
    | UpdateContent new_content -> { model with content = new_content }
    | ToggleMode new_mode -> { model with editableMode = new_mode }
    | SaveFile _path -> 
        (* Here you would implement the logic to save the content to a file *)
        (* For now, we just return the model unchanged *)
        model
end