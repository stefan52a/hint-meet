package nl.zoofit.hintmeet

import androidx.lifecycle.ViewModel
import nl.zoofit.hintmeet.pairing.Pairing
import nl.zoofit.hintmeet.session.Session

/** Dun laagje voor de schermen: alles staat in de Session (die ook de opnameservice gebruikt). */
class AppViewModel : ViewModel() {
    val pairing = Session.pairing
    val connected = Session.connected
    val gateway = Session.gateway
    val projects = Session.projects
    val meeting = Session.meeting
    val pendingPairing = Session.pendingPairing
    val error = Session.error
    val alarms = Session.alarmsNow
    val liveness = Session.liveness
    val sayState = Session.sayState

    fun pair(uri: String?): String? = Session.pair(uri)
    fun offerPairing(uri: String?) = Session.offerPairing(uri)
    fun confirmPairing(shown: Pairing, accept: Boolean) = Session.confirmPairing(shown, accept)
    fun unpair() = Session.unpair()
    fun start(projects: List<String>, language: String, info: String) = Session.start(projects, language, info)
    fun stop() = Session.stop()
    fun feedback(id: Int, rating: Int) = Session.feedback(id, rating)
    fun say(text: String) = Session.say(text)
    fun clearSayError() = Session.clearSayError()
    fun dismissMeeting() = Session.dismissMeeting()
}
