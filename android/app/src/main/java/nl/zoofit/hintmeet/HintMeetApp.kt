package nl.zoofit.hintmeet

import android.app.Application
import nl.zoofit.hintmeet.session.Session

class HintMeetApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Session.init(this)
    }
}
