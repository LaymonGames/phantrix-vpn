#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include "phantrix_plugin.h"

struct _MyApplication {
	GApplication parent_instance;
	FlView* view;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void my_application_activate(GApplication* application) {
	MyApplication* self = MY_APPLICATION(application);
	gtk_window_present(GTK_WINDOW(self->view));
}

static void my_application_dispose(GObject* object) {
	MyApplication* self = MY_APPLICATION(object);
	g_clear_object(&self->view);
	G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
	G_APPLICATION_CLASS(klass)->activate = my_application_activate;
	G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
	self->view = fl_view_new();
	gtk_widget_show(GTK_WIDGET(self->view));

	// Register the Phantrix platform plugin.
	//
	// Flutter's generated registrant already does this for every plugin the
	// app depends on, which is why `generated_plugin_registrant.cc` exists in
	// this directory. Registering it a second time here would install a second
	// method-call handler on the same channel, and the second would silently
	// replace the first — so the registration is left entirely to the
	// generated code, and the call below documents where that happens.
	//
	// The plugin's entry point is `phantrix_plugin_register_with_registrar`,
	// which `flutter/generated_plugin_registrant.cc` invokes with the
	// registrar it obtains from the plugin registry.
	fl_register_plugins(FL_PLUGIN_REGISTRY(self->view));
}

MyApplication* my_application_new() {
	return MY_APPLICATION(
	    g_object_new(my_application_get_type(), "application-id", APPLICATION_ID,
	                  "flags", G_APPLICATION_NON_UNIQUE, NULL));
}
